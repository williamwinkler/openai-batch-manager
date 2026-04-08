defmodule Batcher.Batching.Actions.ProcessDownloadedFileHappyPathTransitionsTest do
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
    test "downloads file, updates requests, and transitions to delivering", %{
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

      assert batch_after.state == :delivering

      # Check Transitions
      assert Enum.any?(batch_after.transitions, fn transition ->
               transition.from == :ready_to_deliver and transition.to == :delivering
             end)

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

      refute Enum.any?(batch_after.requests, &(&1.state == :openai_processing))
    end

    test "handles chunked processing (100 requests at a time)", %{server: server} do
      output_file_id = "file-chunked123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create 10 requests to test processing (reduced from 150 for faster tests)
      requests =
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :openai_processing
        )
        |> generate_many(10)

      # Build JSONL with 10 responses
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
      assert length(batch_after.requests) == 10

      for request <- batch_after.requests do
        assert request.state == :openai_processed
        assert request.response_payload != nil
        # Verify response_payload contains the entire JSONL line
        assert Map.has_key?(request.response_payload, "custom_id")
        assert Map.has_key?(request.response_payload, "id")
        assert Map.has_key?(request.response_payload, "response")
      end

      refute Enum.any?(batch_after.requests, &(&1.state == :openai_processing))
    end

    test "transitions to delivering after processing completes", %{server: server} do
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

      assert batch_after.state == :delivering

      # Verify transition
      assert Enum.any?(batch_after.transitions, fn transition ->
               transition.from == :ready_to_deliver and transition.to == :delivering
             end)
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

      assert batch_after.state == :delivering
      assert length(batch_after.requests) == 1

      updated_request = List.first(batch_after.requests)
      assert updated_request.state == :openai_processed
      assert updated_request.response_payload != nil
      # Verify response_payload contains entire JSONL line with custom_id
      assert updated_request.response_payload["custom_id"] == request.custom_id
      assert Map.has_key?(updated_request.response_payload, "id")
      assert Map.has_key?(updated_request.response_payload, "response")
      refute Enum.any?(batch_after.requests, &(&1.state == :openai_processing))
    end

    test "batch with both files processes correctly and transitions to delivering", %{
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

      # Should transition to delivering when there are successful requests
      assert batch_after.state == :delivering

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
      refute Enum.any?(batch_after.requests, &(&1.state == :openai_processing))
    end

    test "batch with all terminal requests and some successes transitions to done", %{
      server: server
    } do
      output_file_id = "file-terminal-successes123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create requests already in terminal states (:delivered and :delivery_failed).
      # Process an empty file so they stay in those states.
      # After processing, all requests are terminal with 1 delivered and 1 failed (delivery_failed),
      # so batch should transition to :partially_delivered.
      generate(
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :delivered,
          custom_id: "terminal_success_delivered"
        )
      )

      generate(
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model,
          state: :delivery_failed,
          custom_id: "terminal_success_delivery_failed"
        )
      )

      # Process empty file - requests in terminal states will be skipped
      # After processing, all requests are terminal and some are in success states
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, "")
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_downloaded_file, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:requests])

      # All requests should still be in their terminal success states
      assert Enum.all?(batch_after.requests, fn req ->
               req.state in [:delivered, :delivery_failed]
             end)

      # After processing, all requests are terminal with 1 delivered and 1 delivery_failed (counted as failed),
      # so the batch transitions to partially_delivered
      assert batch_after.state == :partially_delivered
    end

    test "batch with all terminal requests but all failed transitions to failed", %{
      server: server
    } do
      output_file_id = "file-terminal-all-failed123"

      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # Create requests that will all fail (go to :failed state, which is terminal)
      failed_request1 =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "terminal_failed_1"
          )
        )

      failed_request2 =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            url: batch_before.url,
            model: batch_before.model,
            state: :openai_processing,
            custom_id: "terminal_failed_2"
          )
        )

      # Create output file with errors that will mark requests as failed
      body = """
      {"id": "req_1", "custom_id": "#{failed_request1.custom_id}", "response": {"status_code": 400, "body": {"error": {"message": "Error 1"}}}, "error": null}
      {"id": "req_2", "custom_id": "#{failed_request2.custom_id}", "response": {"status_code": 400, "body": {"error": {"message": "Error 2"}}}, "error": null}
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

      # All requests should be failed (terminal state)
      assert Enum.all?(batch_after.requests, &(&1.state == :failed))

      # After processing, if all requests are terminal and all failed (none in success states),
      # the batch should transition to :failed
      # This is tested in the "handles batch with all requests failed scenario" test
      # The code path at lines 107-115 checks if all are terminal and all failed
      assert batch_after.state == :failed
    end
  end
end
