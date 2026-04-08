defmodule Batcher.Batching.BatchOpenaiProcessingTransitionsTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  defp assert_has_transition!(transitions, from, to) do
    assert Enum.any?(transitions, fn transition ->
             transition.from == from and transition.to == to
           end)
  end

  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "Batcher.Batching.Batch.start_upload/0" do
    test "sets the state to :uploading" do
      batch = generate(batch())
      # Add a request to the batch (empty batches cannot be uploaded)
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))

      assert batch.state == :building

      result = Batching.start_batch_upload(batch)
      assert {:ok, updated_batch} = result
      assert updated_batch.state == :uploading

      # Verify that a transition record was created
      transitions = Batching.read_batch_by_id!(batch.id, load: [:transitions]).transitions
      assert transitions
      # building -> uploading
      assert length(transitions) == 2
      assert_has_transition!(transitions, :building, :uploading)
    end
  end

  describe "Batcher.Batching.Batch.upload/0" do
    test "transitions batch from uploading to uploaded", %{server: server} do
      batch = generate(batch())
      generate(request(url: batch.url, batch_id: batch.id))

      batch = Batching.start_batch_upload!(batch, load: [:requests])

      assert batch.state == :uploading
      assert length(batch.requests) == 1

      response = %{
        "bytes" => 718,
        "created_at" => 1_766_068_446,
        "expires_at" => 1_768_660_446,
        "filename" => "batch_#{batch.id}.jsonl",
        "id" => "file-1quwTNE3rPZezkuRuGuXaS",
        "object" => "file",
        "purpose" => "batch",
        "status" => "processed",
        "status_details" => nil
      }

      expect_json_response(server, :post, "/v1/files", response, 200)

      # Perform the upload action
      updated_batch =
        batch
        |> Ash.Changeset.for_update(:upload)
        |> Ash.update!(load: [:transitions])

      # Verify the batch state and OpenAI file ID
      assert updated_batch.openai_input_file_id == response["id"]
      assert updated_batch.state == :uploaded

      # building -> uploading -> uploaded
      assert length(updated_batch.transitions) == 3

      assert_has_transition!(updated_batch.transitions, nil, :building)
      assert_has_transition!(updated_batch.transitions, :building, :uploading)
      assert_has_transition!(updated_batch.transitions, :uploading, :uploaded)

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
      refute_enqueued(worker: Batching.Batch.AshOban.Worker.CreateOpenaiBatch)
    end
  end

  describe "Batcher.Batching.Batch.create_openai_batch/0" do
    test "transitions batch from uploaded to openai_processing", %{server: server} do
      openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"

      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: openai_input_file_id))

      generate_many(seeded_request(batch_id: batch.id, url: batch.url), 5)

      response = %{
        # simplified response
        "id" => "batch_69442513cdb08190bc6dbfdfcd2b9b46"
      }

      expect_json_response(server, :post, "/v1/batches", response, 200)

      batch =
        batch
        |> Ash.Changeset.for_update(:create_openai_batch)
        |> Ash.update!(load: [:transitions, :requests])

      assert batch.state == :openai_processing
      assert batch.openai_batch_id == response["id"]

      latest_transition = List.last(batch.transitions)
      assert latest_transition.from == :uploaded
      assert latest_transition.to == :openai_processing
      assert latest_transition.transitioned_at

      # Verify the requests are in state :openai_processing as well
      for request <- batch.requests do
        assert request.state == :openai_processing
      end
    end
  end

  describe "Batcher.Batching.Batch.check_batch_status" do
    @openai_processing_status [
      "validating",
      "in_progress",
      "finalizing"
    ]

    for status <- @openai_processing_status do
      test "OpenAI batch status '#{status}' => batch remains in processing", %{server: server} do
        openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
        openai_batch_id = "batch_69442513cdb08190bc6dbfdfcd2b9b46"

        batch_before =
          seeded_batch(
            state: :openai_processing,
            openai_input_file_id: openai_input_file_id,
            openai_batch_id: openai_batch_id
          )
          |> generate()

        response = %{"status" => unquote(status)}

        # Not set yet
        assert batch_before.openai_status_last_checked_at == nil

        expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

        {:ok, batch_after} =
          Batching.Batch
          |> Ash.ActionInput.for_action(:check_batch_status, %{})
          |> Map.put(:subject, batch_before)
          |> Ash.run_action()

        batch_after = Ash.load!(batch_after, [:transitions])

        assert batch_after.state == :openai_processing
        assert batch_after.openai_status_last_checked_at
        # updated_at should be same or later (allowing for timing precision)
        assert DateTime.compare(batch_after.updated_at, batch_before.updated_at) != :lt

        # We expect no changes, since created with seed
        assert length(batch_after.transitions) == 0
      end
    end

    test "OpenAI batch status 'completed' => batch transitions to openai_completed", %{
      server: server
    } do
      openai_batch_id = "batch_69442513cdb08190bc6dbfdfcd2b9b46"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_input_file_id: "file-1quwTNE3rPZezkuRuGuXaS",
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "completed",
        "output_file_id" => "file-2AbcDNE3rPZezkuRuGuXbB",
        "usage" => %{
          "input_tokens" => 1000,
          "input_tokens_details" => %{"cached_tokens" => 200},
          "output_tokens_details" => %{"reasoning_tokens" => 300},
          "output_tokens" => 800
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :openai_completed
      assert batch_after.openai_output_file_id == response["output_file_id"]
      assert batch_after.openai_status_last_checked_at
      assert batch_after.input_tokens == 1000
      assert batch_after.cached_tokens == 200
      assert batch_after.reasoning_tokens == 300
      assert batch_after.output_tokens == 800
      assert batch_after.updated_at >= batch_before.updated_at

      # Verify transition record
      assert length(batch_after.transitions) == 1
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :openai_completed
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.start_downloading/0" do
    test "sets the state to :downloading" do
      output_file_id = "file-2AbcDNE3rPZezkuRuGuXbB"

      batch_before =
        seeded_batch(
          state: :openai_completed,
          openai_output_file_id: output_file_id
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_downloading)
        |> Ash.update!(load: [:transitions])

      # Verify that a transition record was created
      transitions = batch_after.transitions
      assert transitions
      # openai_completed -> :downloading
      assert Enum.at(transitions, 0).from == :openai_completed
      assert Enum.at(transitions, 0).to == :downloading
      assert Enum.at(transitions, 0).transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.process_downloaded_file/0" do
    test "downloads file, updates requests, and sets state to :delivering", %{
      server: server
    } do
      output_file_id = "file-2AbcDNE3rPZezkuRuGuXbB"

      # 1. Setup Batch in the correct state
      batch_before =
        seeded_batch(
          # The state expected by the process
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # 2. Setup Requests in the correct state (:openai_processing)
      requests =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :openai_processing
        )
        |> generate_many(2)

      cid1 = Enum.at(requests, 0).custom_id
      cid2 = Enum.at(requests, 1).custom_id

      # 3. Setup Mock Response (JSONL body)
      # Note: Simplified JSON for clarity
      body = """
      {"id": "req_1", "custom_id": "#{cid1}", "response": {"status_code": 200, "body": {"output": "result1"}, "error": null}, "error": null}
      {"id": "req_2", "custom_id": "#{cid2}", "response": {"status_code": 200, "body": {"output": "result2"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      # 4. EXECUTE THE GENERIC ACTION
      # Since we defined the action as: action :process_downloaded_file, :struct
      # We call it on the instance 'batch_before'
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # 5. Assertions

      # Reload to check relationships (Transitions & Requests)
      batch_after = Ash.load!(batch_after, [:transitions, :requests])

      assert batch_after.state == :delivering

      # Check Transitions (downloading -> ready_to_deliver -> delivering)
      assert_has_transition!(batch_after.transitions, :ready_to_deliver, :delivering)

      # Check Requests
      assert length(batch_after.requests) == 2

      for request <- batch_after.requests do
        assert request.response_payload != nil
        assert request.state == :openai_processed
      end

      refute Enum.any?(batch_after.requests, &(&1.state == :openai_processing))
    end
  end

  describe "Batcher.Batching.Batch.openai_processing_completed" do
    test "transitions batch to openai_completed with token usage" do
      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: "batch_123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:openai_processing_completed, %{
          openai_output_file_id: "file-output-123",
          input_tokens: 1000,
          cached_tokens: 200,
          reasoning_tokens: 300,
          output_tokens: 800
        })
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :openai_completed
      assert batch_after.openai_output_file_id == "file-output-123"
      assert batch_after.input_tokens == 1000
      assert batch_after.cached_tokens == 200
      assert batch_after.reasoning_tokens == 300
      assert batch_after.output_tokens == 800
      assert batch_after.openai_status_last_checked_at

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :openai_completed
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.finalize_processing" do
    test "transitions batch from downloading to ready_to_deliver" do
      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:finalize_processing)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :ready_to_deliver

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :downloading
      assert latest_transition.to == :ready_to_deliver
      assert latest_transition.transitioned_at
    end
  end
end
