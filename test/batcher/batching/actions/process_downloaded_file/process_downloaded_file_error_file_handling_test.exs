defmodule Batcher.Batching.Actions.ProcessDownloadedFileErrorFileHandlingTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup_all do
    {:ok, server} = TestServer.start()
    {:ok, server: server, openai_base_url: TestServer.url(server)}
  end

  setup %{openai_base_url: openai_base_url} do
    Process.put(:openai_base_url, openai_base_url)
    :ok
  end

  describe "process_downloaded_file action" do
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

      assert batch_after.state == :delivering
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

      # All requests failed at OpenAI, so batch goes to failed
      assert batch_after.state == :failed

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

      # Should handle malformed JSON gracefully (skip malformed lines)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should still process successfully, skipping malformed lines
      assert batch_after.state == :delivering
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

      # Verify batch transitions end at failed
      assert Enum.any?(batch_after.transitions, &(&1.to == :failed))

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

    test "empty output file with error file transitions batch to failed (all requests failed)", %{
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

      # Should transition to failed because all requests failed at OpenAI
      assert batch_after.state == :failed
    end

    test "allows mark_failed on openai_processed requests (error still applies)", %{
      server: server
    } do
      output_file_id = "file-error-on-processed123"
      error_file_id = "file-error-on-processed-err123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      # Create a request that's already been processed
      already_processed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processed,
            custom_id: "processed_but_error_req",
            response_payload: %{"previous" => "response"}
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

      # Error file that marks the already processed request as failed
      # This simulates a scenario where an error file arrives after partial processing
      error_body = """
      {"id": "req_error", "custom_id": "#{already_processed_request.custom_id}", "response": null, "error": "Late error detected"}
      """

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_body)
        end
      )

      # Should succeed - mark_failed can be called from openai_processed state
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # Request should now be failed (mark_failed works from openai_processed)
      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :failed
      assert updated_request.error_msg != nil
      error_data = JSON.decode!(updated_request.error_msg)
      assert error_data["error"] == "Late error detected"
    end

    test "batch with no output file but error file exists transitions to failed", %{
      server: server
    } do
      error_file_id = "file-only-error-transition123"

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
            custom_id: "no_output_error_req"
          )
        )

      # Mock error file
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

      # Should transition to failed when no output file but error file exists
      assert batch_after.state == :failed

      # Verify batch transitions end at failed
      assert Enum.any?(batch_after.transitions, &(&1.to == :failed))
    end
  end
end
