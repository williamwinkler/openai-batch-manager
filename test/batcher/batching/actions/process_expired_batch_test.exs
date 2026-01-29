defmodule Batcher.Batching.Actions.ProcessExpiredBatchTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "process_expired_batch action" do
    test "partial completion: processes output file, resets remaining, and triggers re-upload", %{
      server: server
    } do
      output_file_id = "file-expired-output123"

      batch =
        seeded_batch(
          state: :expired,
          openai_output_file_id: output_file_id,
          openai_input_file_id: "file-old-input"
        )
        |> generate()

      # One request processed by OpenAI (will be in output file)
      processed_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "processed_req"
          )
        )

      # One request NOT processed (not in output file, still openai_processing)
      unprocessed_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "unprocessed_req"
          )
        )

      # Mock output file with only the processed request
      output_body = """
      {"id": "req_1", "custom_id": "#{processed_request.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
      """

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_body)
        end
      )

      # Execute the action
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Immediately after process_expired_batch, batch transitions to :uploading
      assert batch_after.state == :uploading

      # Check that processed request got its response
      processed_req = Ash.get!(Batching.Request, processed_request.id)
      assert processed_req.state == :openai_processed
      assert processed_req.response_payload != nil

      # Check that unprocessed request was reset to :pending
      unprocessed_req = Ash.get!(Batching.Request, unprocessed_request.id)
      assert unprocessed_req.state == :pending

      # Verify upload job was enqueued for re-upload
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.UploadBatch)

      # Verify old input file ID was cleared (new one will be set during upload)
      batch_reloaded = Ash.get!(Batching.Batch, batch.id)
      assert batch_reloaded.openai_input_file_id == nil
      assert batch_reloaded.openai_output_file_id == nil
      assert batch_reloaded.openai_error_file_id == nil
    end

    test "all completed: all requests in output file, batch goes to delivery", %{server: server} do
      output_file_id = "file-expired-all-output"

      batch =
        seeded_batch(
          state: :expired,
          openai_output_file_id: output_file_id
        )
        |> generate()

      # All requests are in the output file
      req1 =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "all_done_1"
          )
        )

      req2 =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "all_done_2"
          )
        )

      output_body = """
      {"id": "req_1", "custom_id": "#{req1.custom_id}", "response": {"status_code": 200, "body": {"output": "result1"}}, "error": null}
      {"id": "req_2", "custom_id": "#{req2.custom_id}", "response": {"status_code": 200, "body": {"output": "result2"}}, "error": null}
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
        |> Ash.ActionInput.for_action(:process_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # All requests were processed, so batch should finalize to ready_to_deliver
      assert batch_after.state == :ready_to_deliver

      # Verify both requests are processed
      req1_after = Ash.get!(Batching.Request, req1.id)
      assert req1_after.state == :openai_processed

      req2_after = Ash.get!(Batching.Request, req2.id)
      assert req2_after.state == :openai_processed
    end

    test "mixed output and error files processed correctly", %{server: server} do
      output_file_id = "file-expired-mixed-output"
      error_file_id = "file-expired-mixed-error"

      batch =
        seeded_batch(
          state: :expired,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      # Success request (in output file)
      success_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "mixed_success"
          )
        )

      # Error request (in error file)
      error_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "mixed_error"
          )
        )

      # Unprocessed request (not in either file)
      unprocessed_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "mixed_unprocessed"
          )
        )

      # Mock output file
      output_body = """
      {"id": "req_s", "custom_id": "#{success_req.custom_id}", "response": {"status_code": 200, "body": {"output": "result"}}, "error": null}
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
      {"id": "req_e", "custom_id": "#{error_req.custom_id}", "response": null, "error": "Rate limit exceeded"}
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
        |> Ash.ActionInput.for_action(:process_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # One pending request remains, so batch re-uploads
      assert batch_after.state == :uploading

      # Verify request states
      success_after = Ash.get!(Batching.Request, success_req.id)
      assert success_after.state == :openai_processed

      error_after = Ash.get!(Batching.Request, error_req.id)
      assert error_after.state == :failed

      unprocessed_after = Ash.get!(Batching.Request, unprocessed_req.id)
      assert unprocessed_after.state == :pending

      # Verify upload job was enqueued
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.UploadBatch)
    end

    test "download failure falls back to full resubmission", %{server: server} do
      output_file_id = "file-expired-fail-output"
      error_file_id = "file-expired-fail-error"

      batch =
        seeded_batch(
          state: :expired,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "fallback_req"
          )
        )

      # Both files fail to download (500 errors)
      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          Plug.Conn.send_resp(conn, 500, "Internal Server Error")
        end
      )

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          Plug.Conn.send_resp(conn, 500, "Internal Server Error")
        end
      )

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:process_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Request should be reset to pending and batch re-uploads
      assert batch_after.state == :uploading

      req_after = Ash.get!(Batching.Request, req.id)
      assert req_after.state == :pending

      # Verify upload job was enqueued
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.UploadBatch)
    end

    test "all requests failed in partial results transitions batch to failed", %{server: server} do
      output_file_id = "file-expired-all-failed"
      error_file_id = "file-expired-all-error"

      batch =
        seeded_batch(
          state: :expired,
          openai_output_file_id: output_file_id,
          openai_error_file_id: error_file_id
        )
        |> generate()

      req1 =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "all_err_1"
          )
        )

      req2 =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "all_err_2"
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

      # Error file with all requests failed
      error_body = """
      {"id": "req_1", "custom_id": "#{req1.custom_id}", "response": null, "error": "Failed"}
      {"id": "req_2", "custom_id": "#{req2.custom_id}", "response": null, "error": "Failed"}
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
        |> Ash.ActionInput.for_action(:process_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # All requests failed, no pending remaining, batch should be failed
      assert batch_after.state == :failed
    end
  end
end
