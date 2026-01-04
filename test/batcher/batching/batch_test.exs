defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
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

  describe "Batcher.Batching.Batch.start_upload/0" do
    test "sets the state to :uploading" do
      batch = generate(batch())

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
    end
  end

  describe "Batcher.Batching.Batch.create_openai_batch/0" do
    test "transitions batch from uploaded to openai_processing", %{server: server} do
      openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"
      batch = generate(seeded_batch(state: :uploaded, openai_input_file_id: openai_input_file_id))
      generate_many(request(batch_id: batch.id, url: batch.url), 5)

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

        batch_after =
          batch_before
          |> Ash.Changeset.for_update(:check_batch_status)
          |> Ash.update!(load: [:transitions])

        assert batch_after.state == :openai_processing
        assert batch_after.openai_status_last_checked_at
        assert batch_after.updated_at >= batch_before.updated_at

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

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:check_batch_status)
        |> Ash.update!(load: [:transitions])

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

  describe "Batcher.Batching.Batch.download/0" do
    test "sets the state to :ready_to_deliver", %{server: server} do
      output_file_id = "file-2AbcDNE3rPZezkuRuGuXbB"
      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create requests associated with the batch
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

      body = """
      {"id": "batch_req_6938b10e2b788190b33b96fd5a082739", "custom_id": "#{cid1}", "response": {"status_code": 200, "request_id": "e6680ccd27fff067f1f8a49c2a5175db", "body": {"id": "resp_011c43705eef9ba0006938b0ab4b488191a657ce33a2fa15c8", "object": "response", "created_at": 1765322923, "status": "completed", "background": false, "billing": {"payer": "developer"}, "error": null, "incomplete_details": null, "instructions": null, "max_output_tokens": null, "max_tool_calls": null, "model": "gpt-4o-mini-2024-07-18", "output": [{"id": "msg_011c43705eef9ba0006938b0ab9bf48191b7fed29fe627a1fa", "type": "message", "status": "completed", "content": [{"type": "output_text", "annotations": [], "logprobs": [], "text": "Go itself does not inherently run inside a virtual machine (VM); it is a compiled language that produces standalone binaries. When you write a Go program, the Go compiler compiles your code into a machine-specific executable. This means that, in typical usage, the compiled Go program runs directly on the operating system without the need for a VM.\n\nHowever, you can run Go applications inside a VM if you choose to do so. For example, you might deploy a Go application inside a VM for various reasons, such as isolation, security, or to match a specific deployment environment. Additionally, when using containerization technologies like Docker, Go applications are often run in containers, which can be orchestrated within VMs. \n\nIn summary, while Go itself does not require a VM to run, it can be executed within a VM depending on your deployment strategy."}], "role": "assistant"}], "parallel_tool_calls": true, "previous_response_id": null, "prompt_cache_key": null, "prompt_cache_retention": null, "reasoning": {"effort": null, "summary": null}, "safety_identifier": null, "service_tier": "default", "store": true, "temperature": 1.0, "text": {"format": {"type": "text"}, "verbosity": "medium"}, "tool_choice": "auto", "tools": [], "top_logprobs": 0, "top_p": 1.0, "truncation": "disabled", "usage": {"input_tokens": 14, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 171, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 185}, "user": null, "metadata": {}}}, "error": null}
      {"id": "batch_req_6938b10d14bc8190b765b1fc7a26fd72", "custom_id": "#{cid2}", "response": {"status_code": 200, "request_id": "bf6efccbef9a917044b9b663a0c1c4aa", "body": {"id": "resp_0ff259abffda64fb006938b0a83c0881a1a2b01c1e1c8adceb", "object": "response", "created_at": 1765322920, "status": "completed", "background": false, "billing": {"payer": "developer"}, "error": null, "incomplete_details": null, "instructions": null, "max_output_tokens": null, "max_tool_calls": null, "model": "gpt-4o-mini-2024-07-18", "output": [{"id": "msg_0ff259abffda64fb006938b0a87a9c81a1801fc0aef3a740db", "type": "message", "status": "completed", "content": [{"type": "output_text", "annotations": [], "logprobs": [], "text": "A red Porsche is, as expected, red! The specific shade can vary, ranging from bright, vibrant red to deeper, darker hues like burgundy. Porsche offers various red shades in their color options, such as Guards Red or Racing Red, each with its own unique character."}], "role": "assistant"}], "parallel_tool_calls": true, "previous_response_id": null, "prompt_cache_key": null, "prompt_cache_retention": null, "reasoning": {"effort": null, "summary": null}, "safety_identifier": null, "service_tier": "default", "store": true, "temperature": 1.0, "text": {"format": {"type": "text"}, "verbosity": "medium"}, "tool_choice": "auto", "tools": [], "top_logprobs": 0, "top_p": 1.0, "truncation": "disabled", "usage": {"input_tokens": 14, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 57, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 71}, "user": null, "metadata": {}}}, "error": null}
      """


      # Mock the download file response
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=\"batch_69386862e3b8819099eaa58934cae79d_output.jsonl\"")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:download)
        |> Ash.update!(load: [:transitions, :requests])

      assert batch_after.state == :ready_to_deliver

      # downloading -> downloaded
      assert Enum.at(batch_after.transitions, 0).from == :downloading
      assert Enum.at(batch_after.transitions, 0).to == :ready_to_deliver
      assert Enum.at(batch_after.transitions, 0).transitioned_at

      assert length(batch_after.requests) == 2
      for request <- batch_after.requests do
        # IO.inspect(request)
        assert request.response_payload != nil
        assert request.state == :openai_processed
      end
    end
  end
end
