defmodule Batcher.Batching.Actions.ProcessDownloadedFileJsonlParsingTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "process_downloaded_file action" do
    test "skips empty lines in JSONL file", %{server: server} do
      output_file_id = "file-empty-lines123"

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
            custom_id: "empty_lines_req"
          )
        )

      # JSONL with empty lines (should be skipped)
      body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}

      {"id": "req_2", "custom_id": "missing_req", "response": {"status_code": 200, "body": {"output": "result2"}}, "error": null}
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

      # Should process successfully, skipping empty lines
      assert batch_after.state == :delivering
      # Only the request with matching custom_id should be processed
      processed_request = Enum.find(batch_after.requests, &(&1.custom_id == request.custom_id))
      assert processed_request != nil
      assert processed_request.state == :openai_processed
    end

    test "handles JSONL with trailing newline", %{server: server} do
      output_file_id = "file-trailing-newline123"

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
            custom_id: "trailing_newline_req"
          )
        )

      # JSONL with trailing newline (common in file outputs)
      body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
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

      # Should process successfully despite trailing newline
      assert batch_after.state == :delivering
      processed_request = List.first(batch_after.requests)
      assert processed_request.state == :openai_processed
    end

    test "handles very large response payloads", %{server: server} do
      output_file_id = "file-large-payload123"

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
            custom_id: "large_payload_req"
          )
        )

      # Create a large response payload (simulating a very long completion)
      large_output = String.duplicate("This is a very long response. ", 1000)

      body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "#{large_output}"}}, "error": null}
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

      # Should handle large payloads successfully
      assert batch_after.state == :delivering
      processed_request = List.first(batch_after.requests)
      assert processed_request.state == :openai_processed
      assert processed_request.response_payload != nil
      assert processed_request.response_payload["response"]["body"]["output"] == large_output
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

    test "handles malformed JSONL lines gracefully", %{server: server} do
      output_file_id = "file-malformed123"

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
            custom_id: "malformed_req"
          )
        )

      # JSONL with malformed JSON line (should be skipped)
      body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
      {invalid json}
      {"id": "req_2", "custom_id": "missing_req", "response": {"status_code": 200, "body": {"output": "result2"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      # Should handle malformed line gracefully (skip it or log error)
      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should still process successfully, skipping malformed line
      assert {:ok, batch_after} = result
      batch_after = Ash.load!(batch_after, [:requests])

      # Should process the valid line
      processed_request = Enum.find(batch_after.requests, &(&1.custom_id == request.custom_id))
      assert processed_request != nil
      assert processed_request.state == :openai_processed
    end

    test "handles JSONL with missing required fields", %{server: server} do
      output_file_id = "file-missing-fields123"

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
            custom_id: "missing_fields_req"
          )
        )

      # JSONL with missing custom_id (should skip or handle gracefully)
      body = """
      {"id": "req_1", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
      {"id": "req_2", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result2"}}, "error": null}
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

      # Should process the line with valid custom_id
      processed_request = Enum.find(batch_after.requests, &(&1.custom_id == request.custom_id))
      assert processed_request != nil
      assert processed_request.state == :openai_processed
    end

    test "handles file processing with malformed JSON lines", %{server: server} do
      output_file_id = "file-malformed-json123"

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
            custom_id: "malformed_json_req"
          )
        )

      # Create a file with valid JSON followed by malformed JSON
      # Malformed lines are skipped gracefully
      invalid_body = """
      {"id": "req_1", "custom_id": "#{request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
      {invalid json that will cause decode error - should be skipped}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, invalid_body)
        end
      )

      # Should handle gracefully (malformed lines are skipped)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should process the valid line
      batch_after = Ash.load!(batch_after, [:requests])
      processed_request = Enum.find(batch_after.requests, &(&1.custom_id == request.custom_id))
      assert processed_request != nil
      assert processed_request.state == :openai_processed
    end
  end
end
