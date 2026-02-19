defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "relationship loading" do
    test "loads batch.prompts relationship" do
      batch = generate(batch())

      # Create multiple requests
      {:ok, req1} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, req2} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_2",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_2",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Load batch with requests (relationship is called :requests, not :prompts)
      batch = Ash.load!(batch, [:requests])

      assert length(batch.requests) == 2
      assert Enum.any?(batch.requests, &(&1.custom_id == req1.custom_id))
      assert Enum.any?(batch.requests, &(&1.custom_id == req2.custom_id))
    end

    test "loads batch.transitions relationship" do
      batch = generate(batch())

      # Load transitions
      batch = Ash.load!(batch, [:transitions])

      # Should have initial transition (nil → :building)
      assert length(batch.transitions) == 1
      transition = List.first(batch.transitions)
      assert transition.from == nil
      assert transition.to == :building
      assert transition.batch_id == batch.id

      # Add a request before transitioning (empty batches cannot be uploaded)
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))
      batch = Batching.get_batch_by_id!(batch.id)

      # Transition to uploading
      {:ok, batch} = Batching.start_batch_upload(batch)
      batch = Ash.load!(batch, [:transitions])

      # Should have 2 transitions now
      assert length(batch.transitions) == 2
    end

    test "loads nested relationships" do
      batch = generate(batch())

      {:ok, _request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Load batch with requests and transitions
      batch = Ash.load!(batch, [:requests, :transitions])

      assert length(batch.requests) == 1
      assert length(batch.transitions) == 1
    end
  end

  describe "Batcher.Batching.create_batch/2" do
    @test_cases Batching.Types.OpenaiBatchEndpoints.values()
                |> Enum.map(fn url ->
                  %{url: url, model: Batcher.Models.model(url)}
                end)

    for test_case <- @test_cases do
      test "create a batch for #{test_case.url} with model #{test_case.model}" do
        model = unquote(test_case.model)
        url = unquote(test_case.url)

        batch = Batching.create_batch!(model, url)

        assert is_integer(batch.id)
        assert batch.state == :building
        assert batch.created_at
        assert batch.updated_at
        assert batch.url == url
        assert batch.model == model
      end
    end

    test "can't create batch with invalid url" do
      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_batch!("gpt-4o-mini", "/v1/invalid-endpoint")
      end
    end

    test "can't create batch with empty model" do
      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_batch!("", "/v1/responses")
      end
    end
  end

  describe "Batcher.Batching.find_build_batch/2" do
    test "finds existing building batch" do
      model = "gpt-4.1-mini"
      url = "/v1/responses"

      # Create a building batch
      batch1 = Batching.create_batch!(model, url)

      # Add a batch in a different state to ensure it is not returned
      generate(seeded_batch(model: model, url: url, state: :uploading))
      generate(seeded_batch(model: model, url: url, state: :openai_processing))
      generate(seeded_batch(model: model, url: url, state: :cancelled))
      generate(batch(model: "different-model", url: url))
      generate(batch(model: model, url: "/v1/chat/completions"))

      building_batch = Batching.find_building_batch!(model, url)

      assert building_batch
      assert building_batch.state == :building
      assert building_batch.id == batch1.id
    end

    test "throws error if no building batch exists" do
      model = "gpt-4.1-mini"
      url = "/v1/responses"

      assert_raise Ash.Error.Invalid, fn ->
        Batching.find_building_batch!(model, url)
      end
    end
  end

  describe "Batcher.Batching.count_batches_for_search" do
    test "counts batches using the same query semantics as search" do
      _ = generate(batch(model: "count-model-a"))
      _ = generate(batch(model: "count-model-b"))
      _ = generate(batch(model: "other-model"))

      {:ok, page} = Batching.search_batches("count-model", page: [limit: 1, count: true])

      {:ok, count_page} =
        Batching.count_batches_for_search("count-model", page: [limit: 1, count: true])

      assert count_page.count == page.count
      assert count_page.count == 2
    end
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
      assert Enum.at(transitions, 1).from == :building
      assert Enum.at(transitions, 1).to == :uploading
      assert Enum.at(transitions, 1).transitioned_at
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

      assert Enum.at(updated_batch.transitions, 0).from == nil
      assert Enum.at(updated_batch.transitions, 0).to == :building

      assert Enum.at(updated_batch.transitions, 1).from == :building
      assert Enum.at(updated_batch.transitions, 1).to == :uploading

      assert Enum.at(updated_batch.transitions, 2).from == :uploading
      assert Enum.at(updated_batch.transitions, 2).to == :uploaded

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
      last_transition = List.last(batch_after.transitions)
      assert last_transition.from == :ready_to_deliver
      assert last_transition.to == :delivering
      assert last_transition.transitioned_at

      # Check Requests
      assert length(batch_after.requests) == 2

      for request <- batch_after.requests do
        assert request.response_payload != nil
        assert request.state == :openai_processed
      end
    end
  end

  describe "Batcher.Batching.Batch.failed" do
    test "transitions batch to failed state with error message" do
      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: "batch_123"
        )
        |> generate()

      error_msg = "Batch processing failed"

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :failed
      assert batch_after.error_msg == error_msg
      assert batch_after.openai_status_last_checked_at

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :failed
      assert latest_transition.transitioned_at
    end

    test "marks all requests as failed when batch fails in openai_processing state" do
      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: "batch_123"
        )
        |> generate()

      # Create requests in different states that can be marked as failed
      states = [:pending, :openai_processing, :openai_processed]

      requests =
        Enum.map(states, fn state ->
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: state
          )
          |> generate()
        end)

      # Mark batch as failed
      error_msg = "Batch processing failed"

      batch_after =
        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update!()

      assert batch_after.state == :failed

      # Reload all requests and verify they are marked as failed
      for req <- requests do
        req_after = Ash.get!(Batcher.Batching.Request, req.id)
        assert req_after.state == :failed
        assert req_after.error_msg == "Batch failed"
      end
    end

    test "does not mark requests as failed when batch fails but not in openai_processing state" do
      batch =
        seeded_batch(
          state: :uploading,
          openai_batch_id: nil
        )
        |> generate()

      reqs =
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :pending
        )
        |> generate_many(2)

      # Mark batch as failed (but it's not in openai_processing state)
      error_msg = "Batch processing failed"

      batch_after =
        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update!()

      assert batch_after.state == :failed

      # Requests should remain in pending state (not marked as failed)
      for req <- reqs do
        req_after = Ash.get!(Batcher.Batching.Request, req.id)
        assert req_after.state == :pending
        assert req_after.error_msg == nil
      end
    end

    test "does not mark requests as failed when batch fails without openai_batch_id" do
      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: nil
        )
        |> generate()

      req =
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :pending
        )
        |> generate()

      # Mark batch as failed (but it has no openai_batch_id)
      error_msg = "Batch processing failed"

      batch_after =
        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update!()

      assert batch_after.state == :failed

      # Request should remain in pending state (not marked as failed)
      req_after = Ash.get!(Batcher.Batching.Request, req.id)
      assert req_after.state == :pending
      assert req_after.error_msg == nil
    end
  end

  describe "Batcher.Batching.Batch.restart" do
    test "transitions failed batch to waiting_for_capacity, clears runtime fields, and enqueues dispatch",
         %{
           server: server
         } do
      expect_json_response(server, :delete, "/v1/files/file_out", %{"id" => "file_out"}, 200)
      expect_json_response(server, :delete, "/v1/files/file_err", %{"id" => "file_err"}, 200)

      batch =
        seeded_batch(
          state: :failed,
          error_msg: ~s({"error":"failed"}),
          openai_batch_id: "batch_old",
          openai_input_file_id: "file_in",
          openai_output_file_id: "file_out",
          openai_error_file_id: "file_err",
          openai_status_last_checked_at: DateTime.utc_now(),
          openai_requests_completed: 4,
          openai_requests_failed: 1,
          openai_requests_total: 5,
          capacity_last_checked_at: DateTime.utc_now(),
          capacity_wait_reason: "insufficient_headroom",
          waiting_for_capacity_since_at: DateTime.utc_now(),
          input_tokens: 1000,
          cached_tokens: 100,
          reasoning_tokens: 50,
          output_tokens: 900,
          expires_at: DateTime.utc_now()
        )
        |> generate()

      generate(
        seeded_request(
          batch_id: batch.id,
          state: :failed,
          error_msg: "failed request",
          response_payload: %{"foo" => "bar"}
        )
      )

      batch_after =
        batch
        |> Ash.Changeset.for_update(:restart)
        |> Ash.update!(load: [:transitions, :requests])

      assert batch_after.state == :waiting_for_capacity
      assert batch_after.error_msg == nil
      assert batch_after.openai_batch_id == nil
      assert batch_after.openai_input_file_id == "file_in"
      assert batch_after.openai_output_file_id == nil
      assert batch_after.openai_error_file_id == nil
      assert batch_after.openai_status_last_checked_at == nil
      assert batch_after.openai_requests_completed == nil
      assert batch_after.openai_requests_failed == nil
      assert batch_after.openai_requests_total == nil
      assert batch_after.capacity_last_checked_at == nil
      assert batch_after.capacity_wait_reason == nil
      assert batch_after.waiting_for_capacity_since_at
      assert batch_after.input_tokens == nil
      assert batch_after.cached_tokens == nil
      assert batch_after.reasoning_tokens == nil
      assert batch_after.output_tokens == nil
      assert batch_after.expires_at == nil

      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :failed
      assert latest_transition.to == :waiting_for_capacity

      assert_enqueued(
        worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity,
        queue: :capacity_dispatch
      )
    end

    test "resets restartable request states to pending and clears response/error fields" do
      batch =
        seeded_batch(
          state: :failed,
          openai_input_file_id: "file_in"
        )
        |> generate()

      failed_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :failed,
            error_msg: "request failed",
            response_payload: %{"status" => "failed"}
          )
        )

      processed_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :openai_processed,
            error_msg: "old error",
            response_payload: %{"status" => "ok"}
          )
        )

      pending_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :pending,
            error_msg: nil,
            response_payload: nil
          )
        )

      _batch_after =
        batch
        |> Ash.Changeset.for_update(:restart)
        |> Ash.update!()

      failed_request_after = Ash.get!(Batching.Request, failed_request.id)
      processed_request_after = Ash.get!(Batching.Request, processed_request.id)
      pending_request_after = Ash.get!(Batching.Request, pending_request.id)

      assert failed_request_after.state == :pending
      assert failed_request_after.error_msg == nil
      assert failed_request_after.response_payload == nil

      assert processed_request_after.state == :pending
      assert processed_request_after.error_msg == nil
      assert processed_request_after.response_payload == nil

      assert pending_request_after.state == :pending
    end

    test "rejects restart for non-failed batch" do
      batch = generate(batch())

      assert_raise Ash.Error.Invalid, fn ->
        batch
        |> Ash.Changeset.for_update(:restart)
        |> Ash.update!()
      end
    end

    test "rejects restart for failed batch without input file id" do
      batch =
        seeded_batch(
          state: :failed,
          openai_input_file_id: nil
        )
        |> generate()

      assert_raise Ash.Error.Invalid, fn ->
        batch
        |> Ash.Changeset.for_update(:restart)
        |> Ash.update!()
      end
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

  describe "Batcher.Batching.Batch.start_delivering" do
    test "transitions batch from ready_to_deliver to delivering" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_delivering)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivering

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :ready_to_deliver
      assert latest_transition.to == :delivering
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.mark_delivered" do
    test "transitions batch from delivering to delivered" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_delivered)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivered

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :delivered
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.mark_partially_delivered" do
    test "transitions batch from delivering to partially_delivered" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_partially_delivered)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :partially_delivered

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :partially_delivered
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.mark_delivery_failed" do
    test "transitions batch from delivering to delivery_failed" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_delivery_failed)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivery_failed

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :delivery_failed
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.cancel" do
    test "transitions batch to cancelled state", %{server: server} do
      openai_batch_id = "batch_123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock successful cancel response
      cancel_response = %{
        "id" => openai_batch_id,
        "status" => "cancelling",
        "object" => "batch"
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        200
      )

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:cancel)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :cancelled

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :cancelled
      assert latest_transition.transitioned_at
    end

    test "can cancel batch from different states", %{server: server} do
      states = [:building, :uploading, :uploaded, :openai_processing]

      for state <- states do
        openai_batch_id = if state == :openai_processing, do: "batch_#{state}", else: nil

        batch_before =
          seeded_batch(
            state: state,
            openai_batch_id: openai_batch_id
          )
          |> generate()

        # Only mock API call for openai_processing state
        if state == :openai_processing do
          cancel_response = %{
            "id" => openai_batch_id,
            "status" => "cancelling",
            "object" => "batch"
          }

          expect_json_response(
            server,
            :post,
            "/v1/batches/#{openai_batch_id}/cancel",
            cancel_response,
            200
          )
        end

        batch_after =
          batch_before
          |> Ash.Changeset.for_update(:cancel)
          |> Ash.update!(load: [:transitions])

        assert batch_after.state == :cancelled

        latest_transition = List.last(batch_after.transitions)
        assert latest_transition.from == state
        assert latest_transition.to == :cancelled
      end
    end
  end

  describe "Batcher.Batching.Batch.mark_expired" do
    test "transitions from openai_processing to expired and triggers capacity dispatch", %{
      server: server
    } do
      openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: "batch_123",
          openai_input_file_id: openai_input_file_id
        )
        |> generate()

      # Ensure batch has at least one request (use seeded_request to bypass state validation)
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))

      # Mock the new batch creation (using existing file ID)
      new_batch_response = %{
        "id" => "batch_new456",
        "status" => "validating",
        "input_file_id" => openai_input_file_id
      }

      expect_json_response(server, :post, "/v1/batches", new_batch_response, 200)

      # Reload batch from database to ensure we have the correct state
      # This is important because seeded_batch bypasses actions and the struct
      # might not reflect the actual database state
      batch = Ash.get!(Batching.Batch, batch.id)

      # Verify the batch is in the expected state before transitioning
      assert batch.state == :openai_processing

      {:ok, batch_after} =
        batch
        |> Ash.Changeset.for_update(:mark_expired, %{})
        |> Ash.update()

      # Should be in expired state (oban trigger will move it to openai_processing)
      assert batch_after.state == :expired
      # These should be unset
      assert batch_after.openai_status_last_checked_at == nil
      assert batch_after.expires_at == nil
      assert batch_after.openai_batch_id == nil

      # Drain the capacity dispatch queue to process the triggered capacity dispatch job
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
      Oban.drain_queue(queue: :capacity_dispatch)

      # Reload the batch to see the final state
      batch_final = Ash.get!(Batching.Batch, batch_after.id, load: [:transitions])

      assert batch_final.state == :openai_processing
      assert batch_final.openai_batch_id == "batch_new456"

      # Verify transition records - should have 2 transitions:
      # 1. openai_processing → expired
      # 2. expired → openai_processing
      assert length(batch_final.transitions) >= 2
      transitions = Enum.sort_by(batch_final.transitions, & &1.transitioned_at)
      recent_transitions = Enum.take(transitions, -2)

      first_transition = Enum.at(recent_transitions, 0)
      assert first_transition.from == :openai_processing
      assert first_transition.to == :expired

      second_transition = Enum.at(recent_transitions, 1)
      assert second_transition.from == :expired
      assert second_transition.to == :openai_processing
    end

    test "fails if batch is not in openai_processing state" do
      batch = generate(seeded_batch(state: :building))

      result =
        batch
        |> Ash.Changeset.for_update(:mark_expired, %{})
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "unsets expires_at, openai_status_last_checked_at, and openai_batch_id when marking as expired" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      last_checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: "batch_123",
          openai_input_file_id: "file-123",
          expires_at: expires_at,
          openai_status_last_checked_at: last_checked_at
        )
        |> generate()

      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model))

      {:ok, batch_after} =
        batch
        |> Ash.Changeset.for_update(:mark_expired, %{})
        |> Ash.update()

      # These should be unset immediately
      assert batch_after.openai_status_last_checked_at == nil
      assert batch_after.expires_at == nil
      assert batch_after.openai_batch_id == nil
      assert batch_after.state == :expired

      # Oban job should be enqueued for capacity-aware dispatch
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
    end
  end
end
