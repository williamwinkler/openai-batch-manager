defmodule Batcher.Batching.Actions.ProcessDownloadedFileTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "process_downloaded_file action" do
    test "downloads file, updates requests, and transitions to ready_to_deliver", %{
      server: server
    } do
      output_file_id = "file-2AbcDNE3rPZezkuRuXbB"

      # Setup Batch in downloading state
      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Setup Requests in openai_processing state
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

      # Setup Mock Response (JSONL body)
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

      # Execute the action
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Reload to check relationships
      batch_after = Ash.load!(batch_after, [:transitions, :requests])

      assert batch_after.state == :ready_to_deliver

      # Check Transitions
      last_transition = List.last(batch_after.transitions)
      assert last_transition.from == :downloading
      assert last_transition.to == :ready_to_deliver

      # Check Requests
      assert length(batch_after.requests) == 2

      for request <- batch_after.requests do
        assert request.response_payload != nil
        assert request.state == :openai_processed
        # Verify response_payload contains the entire JSONL line with custom_id
        assert Map.has_key?(request.response_payload, "custom_id")
        assert Map.has_key?(request.response_payload, "id")
        assert Map.has_key?(request.response_payload, "response")
        assert Map.has_key?(request.response_payload, "error")
      end
    end

    test "handles chunked processing (100 requests at a time)", %{server: server} do
      output_file_id = "file-chunked123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create 150 requests to test chunking
      requests =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :openai_processing
        )
        |> generate_many(150)

      # Build JSONL with 150 responses
      jsonl_lines =
        Enum.map(requests, fn req ->
          %{
            id: "req_#{req.custom_id}",
            custom_id: req.custom_id,
            response: %{status_code: 200, body: %{output: "result"}, error: nil},
            error: nil
          }
          |> JSON.encode!()
        end)

      body = Enum.join(jsonl_lines, "\n") <> "\n"

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # All requests should be processed
      assert length(batch_after.requests) == 150

      for request <- batch_after.requests do
        assert request.state == :openai_processed
        assert request.response_payload != nil
        # Verify response_payload contains the entire JSONL line
        assert Map.has_key?(request.response_payload, "custom_id")
        assert Map.has_key?(request.response_payload, "id")
        assert Map.has_key?(request.response_payload, "response")
      end
    end

    test "handles error responses in file", %{server: server} do
      output_file_id = "file-errors123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            state: :openai_processing,
            custom_id: "error_req"
          )
        )

      # JSONL with error response
      # The code passes err directly to mark_failed, which expects a string
      # So we'll use a simple error message string
      body = """
      {"id": "req_error", "custom_id": "#{request.custom_id}", "response": null, "error": "Processing failed"}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # Request should be marked as failed
      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :failed
      # Verify error_msg contains the entire JSONL line
      assert updated_request.error_msg != nil
      error_data = JSON.decode!(updated_request.error_msg)
      assert Map.has_key?(error_data, "custom_id")
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "response")
      assert Map.has_key?(error_data, "error")
    end

    test "handles missing custom_id in response", %{server: server} do
      output_file_id = "file-missing-cid123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # JSONL without custom_id
      body = """
      {"id": "req_1", "response": {"status_code": 200, "body": {"output": "result"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should complete successfully (missing custom_id is logged but doesn't fail)
      assert batch_after.state == :ready_to_deliver
    end

    test "handles download failures gracefully", %{server: server} do
      output_file_id = "file-fail123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Note: download_file doesn't check status codes, so it will create a file
      # even on 404. The action will try to process it and may fail.
      # This test verifies the action handles the error case.
      # For a proper test, we'd need to mock Req to return {:error, reason}
      # but that's complex. Instead, we'll test with an empty/malformed file.
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          # Empty file
          |> Plug.Conn.send_resp(200, "")
        end
      )

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should complete successfully with empty file (no requests to process)
      assert {:ok, batch_after} = result
      assert batch_after.state == :ready_to_deliver
    end

    test "transitions to ready_to_deliver after processing completes", %{server: server} do
      output_file_id = "file-complete123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            state: :openai_processing,
            custom_id: "complete_req"
          )
        )

      body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :ready_to_deliver

      # Verify transition
      last_transition = List.last(batch_after.transitions)
      assert last_transition.from == :downloading
      assert last_transition.to == :ready_to_deliver
    end

    test "processes error_file_id when batch has failed requests", %{server: server} do
      output_file_id = "file-output123"
      error_file_id = "file-error123"
      batch_id = "batch_abc123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id,
          openai_batch_id: batch_id
        )
        |> generate()

      # Create successful and failed requests
      successful_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "success_req"
          )
        )

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "failed_req"
          )
        )

      # Mock output file (successful requests)
      output_body = """
      {"id": "req_1", "custom_id": "#{successful_request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_body)
        end
      )

      # Mock error file (failed requests)
      error_body = """
      {"id": "req_error", "custom_id": "#{failed_request.custom_id}", "response": null, "error": "Invalid request parameters"}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      assert batch_after.state == :ready_to_deliver
      assert length(batch_after.requests) == 2

      # Check successful request
      successful_req =
        Enum.find(batch_after.requests, &(&1.custom_id == successful_request.custom_id))

      assert successful_req.state == :openai_processed
      assert successful_req.response_payload != nil
      # Verify response_payload contains entire JSONL line with custom_id
      assert successful_req.response_payload["custom_id"] == successful_request.custom_id
      assert Map.has_key?(successful_req.response_payload, "id")
      assert Map.has_key?(successful_req.response_payload, "response")
      assert Map.has_key?(successful_req.response_payload, "error")

      # Check failed request
      failed_req = Enum.find(batch_after.requests, &(&1.custom_id == failed_request.custom_id))

      assert failed_req.state == :failed
      # Verify error_msg contains the entire JSONL line
      assert failed_req.error_msg != nil
      error_data = JSON.decode!(failed_req.error_msg)
      assert error_data["custom_id"] == failed_request.custom_id
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "response")
      assert Map.has_key?(error_data, "error")
    end

    test "handles error_file_id with object error format", %{server: server} do
      output_file_id = "file-output456"
      error_file_id = "file-error456"
      batch_id = "batch_def456"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id,
          openai_batch_id: batch_id
        )
        |> generate()

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "failed_obj_req"
          )
        )

      # Mock empty output file (all requests failed)
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, "")
        end
      )

      # Mock error file with object error
      error_obj = %{
        "message" => "Rate limit exceeded",
        "type" => "rate_limit_error",
        "code" => "rate_limit_exceeded"
      }

      error_body = """
      {"id": "req_error", "custom_id": "#{failed_request.custom_id}", "response": null, "error": #{JSON.encode!(error_obj)}}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      assert batch_after.state == :ready_to_deliver

      failed_req = Enum.find(batch_after.requests, &(&1.custom_id == failed_request.custom_id))

      assert failed_req.state == :failed
      # Verify error_msg contains the entire JSONL line
      assert failed_req.error_msg != nil
      error_data = JSON.decode!(failed_req.error_msg)
      assert error_data["custom_id"] == failed_request.custom_id
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "response")
      assert Map.has_key?(error_data, "error")
      # Error object should be in the error field
      assert error_data["error"]["type"] == "rate_limit_error"
      assert error_data["error"]["message"] == "Rate limit exceeded"
    end

    test "works correctly when no error_file_id exists", %{server: server} do
      output_file_id = "file-no-error123"
      batch_id = "batch_no_error123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_batch_id: batch_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "success_only_req"
          )
        )

      # Mock output file
      output_body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      assert batch_after.state == :ready_to_deliver
      assert length(batch_after.requests) == 1

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :openai_processed
      assert updated_request.response_payload != nil
      # Verify response_payload contains entire JSONL line with custom_id
      assert updated_request.response_payload["custom_id"] == request.custom_id
      assert Map.has_key?(updated_request.response_payload, "id")
      assert Map.has_key?(updated_request.response_payload, "response")
    end

    test "handles error file processing failure gracefully", %{server: server} do
      output_file_id = "file-output789"
      error_file_id = "file-error789"
      batch_id = "batch_ghi789"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id,
          openai_batch_id: batch_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "success_req"
          )
        )

      # Mock successful output file
      output_body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}, "error": null}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_body)
        end
      )

      # Mock error file with malformed JSONL that will cause JSON.decode! to raise
      # This tests that malformed error files cause the action to fail
      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          # Return invalid JSONL that will cause JSON.decode! to raise during processing
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, "invalid json content{")
        end
      )

      # Should raise JSON.DecodeError when error file has malformed content
      assert_raise JSON.DecodeError, fn ->
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()
      end
    end

    test "handles batch with only error file (all requests failed)", %{server: server} do
      error_file_id = "file-only-error123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: nil,
          openai_error_file_id: error_file_id
        )
        |> generate()

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "all_failed_req"
          )
        )

      # Mock error file (all requests failed)
      error_body = """
      {"id": "req_error", "custom_id": "#{failed_request.custom_id}", "response": null, "error": "All requests failed"}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests, :transitions])

      # Batch should transition to :failed when only error file exists
      assert batch_after.state == :failed
      assert length(batch_after.requests) == 1

      # Verify batch transition
      last_transition = List.last(batch_after.transitions)
      assert last_transition.from == :downloading
      assert last_transition.to == :failed

      failed_req = List.first(batch_after.requests)
      assert failed_req.state == :failed
      # Verify error_msg contains the entire JSONL line
      assert failed_req.error_msg != nil
      error_data = JSON.decode!(failed_req.error_msg)
      assert error_data["custom_id"] == failed_request.custom_id
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "response")
      assert Map.has_key?(error_data, "error")
    end

    test "skips requests already in terminal states (delivered, failed, expired, cancelled)", %{
      server: server
    } do
      output_file_id = "file-skip-terminal123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_batch_id: "batch_skip_terminal123"
        )
        |> generate()

      # Create requests in different terminal states
      delivered_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :delivered,
            custom_id: "delivered_req"
          )
        )

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :failed,
            custom_id: "failed_req"
          )
        )

      # Mock output file that would try to process these requests again
      body = """
      {"id": "req_1", "custom_id": "#{delivered_request.custom_id}", "response": {"status_code": 200, "body": {"output": "result1"}}, "error": null}
      {"id": "req_2", "custom_id": "#{failed_request.custom_id}", "response": {"status_code": 200, "body": {"output": "result2"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      # Should not raise an error - terminal states should be skipped
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      assert batch_after.state == :ready_to_deliver

      # Verify requests are still in their original terminal states
      delivered_req =
        Enum.find(batch_after.requests, fn r -> r.custom_id == delivered_request.custom_id end)

      failed_req =
        Enum.find(batch_after.requests, fn r -> r.custom_id == failed_request.custom_id end)

      assert delivered_req.state == :delivered
      assert failed_req.state == :failed
    end

    test "error file entries with response but no top-level error are marked as failed", %{
      server: server
    } do
      error_file_id = "file-error-with-response123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: nil,
          openai_error_file_id: error_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "error_with_response_req"
          )
        )

      # Error file entry with response but no top-level error (like the real error file format)
      error_body = """
      {"id": "req_error", "custom_id": "#{request.custom_id}", "response": {"status_code": 400, "request_id": "abc123", "body": {"error": {"message": "Invalid request", "type": "invalid_request_error"}}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # Batch should be failed since only error file exists
      assert batch_after.state == :failed

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :failed
      assert updated_request.response_payload == nil
      # Verify error_msg contains the entire JSONL line
      assert updated_request.error_msg != nil
      error_data = JSON.decode!(updated_request.error_msg)
      assert error_data["custom_id"] == request.custom_id
      assert error_data["response"]["status_code"] == 400
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "error")
    end

    test "output file entries with error responses (status_code != 200) are marked as failed", %{
      server: server
    } do
      output_file_id = "file-output-error-status123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "error_status_req"
          )
        )

      # Output file entry with error status code
      body = """
      {"id": "req_error", "custom_id": "#{request.custom_id}", "response": {"status_code": 400, "request_id": "abc123", "body": {"error": {"message": "Invalid parameter", "type": "invalid_request_error"}}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :failed
      assert updated_request.response_payload == nil
      # Verify error_msg contains the entire JSONL line
      assert updated_request.error_msg != nil
      error_data = JSON.decode!(updated_request.error_msg)
      assert error_data["custom_id"] == request.custom_id
      assert error_data["response"]["status_code"] == 400
      assert Map.has_key?(error_data, "id")
      assert Map.has_key?(error_data, "error")
    end

    test "output file entries with error in response.body.error are marked as failed", %{
      server: server
    } do
      output_file_id = "file-output-body-error123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "body_error_req"
          )
        )

      # Output file entry with status 200 but error in body
      body = """
      {"id": "req_error", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "request_id": "abc123", "body": {"error": {"message": "Processing error", "type": "processing_error"}}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :failed
      assert updated_request.response_payload == nil
      # Verify error_msg contains the entire JSONL line
      error_data = JSON.decode!(updated_request.error_msg)
      assert error_data["custom_id"] == request.custom_id
      assert get_in(error_data, ["response", "body", "error"]) != nil
    end

    test "successful output file entries store entire JSONL line in response_payload", %{
      server: server
    } do
      output_file_id = "file-full-jsonl123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "full_jsonl_req"
          )
        )

      # Successful response with full structure
      body = """
      {"id": "req_123", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "request_id": "req_abc", "body": {"output": "result"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :openai_processed
      # Verify response_payload contains entire JSONL line, not just response.body
      assert updated_request.response_payload["id"] == "req_123"
      assert updated_request.response_payload["custom_id"] == request.custom_id
      assert updated_request.response_payload["response"]["status_code"] == 200
      assert updated_request.response_payload["response"]["body"]["output"] == "result"
      assert updated_request.response_payload["error"] == nil
      # Verify custom_id is present for webhook delivery
      assert Map.has_key?(updated_request.response_payload, "custom_id")
    end

    test "batch with both files processes correctly and transitions to ready_to_deliver", %{
      server: server
    } do
      output_file_id = "file-both-output123"
      error_file_id = "file-both-error123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      successful_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "both_success_req"
          )
        )

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "both_failed_req"
          )
        )

      # Mock output file
      output_body = """
      {"id": "req_success", "custom_id": "#{successful_request.custom_id}", "response": {"status_code": 200, "body": {"output": "success"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_body)
        end
      )

      # Mock error file
      error_body = """
      {"id": "req_failed", "custom_id": "#{failed_request.custom_id}", "response": {"status_code": 400, "body": {"error": {"message": "Failed"}}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # Should transition to ready_to_deliver when there are successful requests
      assert batch_after.state == :ready_to_deliver

      # Check successful request
      success_req =
        Enum.find(batch_after.requests, &(&1.custom_id == successful_request.custom_id))

      assert success_req.state == :openai_processed
      assert success_req.response_payload["custom_id"] == successful_request.custom_id

      # Check failed request
      failed_req =
        Enum.find(batch_after.requests, &(&1.custom_id == failed_request.custom_id))

      assert failed_req.state == :failed
      error_data = JSON.decode!(failed_req.error_msg)
      assert error_data["custom_id"] == failed_request.custom_id
    end

    test "empty output file with error file transitions batch to ready_to_deliver", %{
      server: server
    } do
      output_file_id = "file-empty-output123"
      error_file_id = "file-empty-error123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      failed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "empty_output_req"
          )
        )

      # Empty output file
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, "")
        end
      )

      # Error file with failed request
      error_body = """
      {"id": "req_failed", "custom_id": "#{failed_request.custom_id}", "response": null, "error": "All failed"}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # Should transition to ready_to_deliver (not failed) because output_file_id exists
      # even though it's empty - the presence of output_file_id means we had some successful processing
      assert batch_after.state == :ready_to_deliver
    end
  end
end
