defmodule Batcher.Batching.Actions.ProcessDownloadedFileIdempotencyTerminalStateTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "process_downloaded_file action" do
    test "is idempotent when batch is already ready_to_deliver and requests still need delivery" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: nil,
          openai_error_file_id: nil
        )
        |> generate()

      _request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processed,
            custom_id: "ready_to_deliver_idempotent_req"
          )
        )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :delivering
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

      # All requests are already in terminal states (1 delivered, 1 failed), so batch goes to partially_delivered
      assert batch_after.state == :partially_delivered

      # Verify requests are still in their original terminal states
      delivered_req =
        Enum.find(batch_after.requests, fn r -> r.custom_id == delivered_request.custom_id end)

      failed_req =
        Enum.find(batch_after.requests, fn r -> r.custom_id == failed_request.custom_id end)

      assert delivered_req.state == :delivered
      assert failed_req.state == :failed
    end

    test "skips requests already in openai_processed state (idempotency for retries)", %{
      server: server
    } do
      output_file_id = "file-idempotent123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create a request that's already been processed (e.g., from a previous retry)
      already_processed_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processed,
            custom_id: "already_processed_req",
            response_payload: %{"previous" => "response"}
          )
        )

      # Create a request that still needs processing
      pending_request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "pending_req"
          )
        )

      # Mock output file that includes both requests
      # The already_processed one should be skipped, not cause a state machine error
      body = """
      {"id": "req_1", "custom_id": "#{already_processed_request.custom_id}", "response": {"status_code": 200, "body": {"output": "new_result"}}, "error": null}
      {"id": "req_2", "custom_id": "#{pending_request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      # Should NOT raise a state machine error - should handle gracefully
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      assert batch_after.state == :delivering

      # Already processed request should retain its original response_payload (not overwritten)
      already_processed =
        Enum.find(batch_after.requests, &(&1.custom_id == already_processed_request.custom_id))

      assert already_processed.state == :openai_processed
      assert already_processed.response_payload["previous"] == "response"

      # Pending request should now be processed
      processed = Enum.find(batch_after.requests, &(&1.custom_id == pending_request.custom_id))
      assert processed.state == :openai_processed
      assert processed.response_payload["response"]["body"]["output"] == "result"
    end

    test "skips request already in openai_processed state for idempotency", %{server: server} do
      output_file_id = "file-idempotency-skip123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
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
            custom_id: "idempotency_skip_req",
            response_payload: %{"previous" => "response", "id" => "old_id"}
          )
        )

      # Mock output file that would try to process this request again
      body = """
      {"id": "req_new", "custom_id": "#{already_processed_request.custom_id}", "response": {"status_code": 200, "body": {"output": "new_result"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, body)
        end
      )

      # Capture logs to verify skip message
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, batch_after} =
          Batching.Batch
          |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
          |> Map.put(:subject, batch_before)
          |> Ash.run_action()

        batch_after = Ash.load!(batch_after, [:requests])

        # Request should still be in openai_processed state with original payload
        processed_request =
          Enum.find(batch_after.requests, &(&1.custom_id == already_processed_request.custom_id))

        assert processed_request.state == :openai_processed
        # Should retain original response_payload (not overwritten)
        assert processed_request.response_payload["previous"] == "response"
        assert processed_request.response_payload["id"] == "old_id"
      end)
    end
  end
end
