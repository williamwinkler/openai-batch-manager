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

      # All requests were processed, so batch should finalize to delivering
      assert batch_after.state == :delivering

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

    test "e2e: check_batch_status detects expiration, processes partial results, re-uploads only pending requests",
         %{server: server} do
      openai_batch_id = "batch_abc123def456"
      original_input_file_id = "file-8kXqR2nWp4mY7vBc"
      output_file_id = "file-3jHnKp9sLm2xWqYz"
      error_file_id = "file-7rTvNx4wQd6sFgAb"

      # Start with a batch in openai_processing (as it would be in production)
      batch =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: original_input_file_id
        )
        |> generate()

      # 3 requests submitted to OpenAI, all in openai_processing state
      success_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "req-success-001"
          )
        )

      failed_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "req-failed-002"
          )
        )

      unprocessed_req =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing,
            custom_id: "req-pending-003"
          )
        )

      # ── Mock 1: OpenAI batch status returns "expired" with partial file IDs ──
      # This is what OpenAI returns when a batch times out after 24h
      expired_status_response = %{
        "id" => openai_batch_id,
        "object" => "batch",
        "endpoint" => "/v1/responses",
        "status" => "expired",
        "input_file_id" => original_input_file_id,
        "output_file_id" => output_file_id,
        "error_file_id" => error_file_id,
        "created_at" => System.os_time(:second) - 86_400,
        "expired_at" => System.os_time(:second),
        "request_counts" => %{
          "total" => 3,
          "completed" => 1,
          "failed" => 1
        }
      }

      TestServer.add(server, "/v1/batches/#{openai_batch_id}",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, JSON.encode!(expired_status_response))
        end
      )

      # ── Mock 2: Download partial output file (1 successful request) ──
      output_jsonl =
        [
          JSON.encode!(%{
            "id" => "resp_5gH2kM8nP3qR",
            "custom_id" => success_req.custom_id,
            "response" => %{
              "status_code" => 200,
              "request_id" => "req_abc123",
              "body" => %{
                "id" => "chatcmpl-9x8w7v6u5t",
                "object" => "chat.completion",
                "model" => batch.model,
                "choices" => [
                  %{
                    "index" => 0,
                    "message" => %{
                      "role" => "assistant",
                      "content" => "The answer to your question is 42."
                    }
                  }
                ],
                "usage" => %{
                  "prompt_tokens" => 15,
                  "completion_tokens" => 10,
                  "total_tokens" => 25
                }
              }
            },
            "error" => nil
          })
        ]
        |> Enum.join("\n")

      TestServer.add(server, "/v1/files/#{output_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, output_jsonl)
        end
      )

      # ── Mock 3: Download partial error file (1 failed request) ──
      error_jsonl =
        [
          JSON.encode!(%{
            "id" => "resp_7jK4mN6pQ8sT",
            "custom_id" => failed_req.custom_id,
            "response" => %{
              "status_code" => 429,
              "request_id" => "req_def456",
              "body" => %{
                "error" => %{
                  "message" => "Rate limit reached for model",
                  "type" => "rate_limit_error",
                  "code" => "rate_limit_exceeded"
                }
              }
            },
            "error" => nil
          })
        ]
        |> Enum.join("\n")

      TestServer.add(server, "/v1/files/#{error_file_id}/content",
        via: :get,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, error_jsonl)
        end
      )

      # ── Mock 4: File re-upload for unprocessed requests ──
      test_pid = self()
      new_expires_at = System.os_time(:second) + 30 * 24 * 60 * 60

      TestServer.add(server, "/v1/files",
        via: :post,
        to: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:uploaded_body, body})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            JSON.encode!(%{
              "id" => "file-9nWqYz3kLm8x",
              "object" => "file",
              "bytes" => 256,
              "created_at" => System.os_time(:second),
              "filename" => "batch_#{batch.id}.jsonl",
              "purpose" => "batch",
              "expires_at" => new_expires_at
            })
          )
        end
      )

      # ── Mock 5: New OpenAI batch creation ──
      TestServer.add(server, "/v1/batches",
        via: :post,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            JSON.encode!(%{
              "id" => "batch_newXyz789",
              "object" => "batch",
              "endpoint" => "/v1/responses",
              "status" => "validating",
              "input_file_id" => "file-9nWqYz3kLm8x",
              "created_at" => System.os_time(:second),
              "request_counts" => %{"total" => 1, "completed" => 0, "failed" => 0}
            })
          )
        end
      )

      # ════════════════════════════════════════════════════════════════
      # Phase 1: check_batch_status detects expiration with partial results
      # ════════════════════════════════════════════════════════════════
      {:ok, batch_after_check} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should transition to :expired with file IDs stored
      assert batch_after_check.state == :expired
      assert batch_after_check.openai_output_file_id == output_file_id
      assert batch_after_check.openai_error_file_id == error_file_id
      assert batch_after_check.openai_batch_id == nil
      assert batch_after_check.openai_status_last_checked_at == nil

      # ════════════════════════════════════════════════════════════════
      # Phase 2: Drain batch_processing queue → runs process_expired_batch
      #          Downloads files, processes results, resets unprocessed, triggers re-upload
      # ════════════════════════════════════════════════════════════════
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessExpiredBatch)
      Oban.drain_queue(queue: :batch_processing)

      # Verify request states after processing partial results
      success_after = Ash.get!(Batching.Request, success_req.id)
      assert success_after.state == :openai_processed
      assert success_after.response_payload["response"]["body"]["choices"] != nil

      failed_after = Ash.get!(Batching.Request, failed_req.id)
      assert failed_after.state == :failed
      assert failed_after.error_msg != nil
      error_data = JSON.decode!(failed_after.error_msg)
      assert error_data["response"]["status_code"] == 429

      unprocessed_after = Ash.get!(Batching.Request, unprocessed_req.id)
      assert unprocessed_after.state == :pending

      batch_after_process = Ash.get!(Batching.Batch, batch.id)
      assert batch_after_process.state == :uploading

      # ════════════════════════════════════════════════════════════════
      # Phase 3: Drain batch_uploads queue → re-uploads only the 1 pending request
      # ════════════════════════════════════════════════════════════════
      Oban.drain_queue(queue: :batch_uploads)

      # Verify exactly 1 JSONL line was uploaded (the unprocessed request)
      assert_received {:uploaded_body, uploaded_body}

      jsonl_lines =
        uploaded_body
        |> String.split("\n")
        |> Enum.filter(fn line ->
          trimmed = String.trim(line)
          String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
        end)

      assert length(jsonl_lines) == 1,
             "Expected exactly 1 JSONL line (the unprocessed request) but got #{length(jsonl_lines)}"

      batch_after_upload = Ash.get!(Batching.Batch, batch.id)
      assert batch_after_upload.state == :uploaded
      assert batch_after_upload.openai_input_file_id == "file-9nWqYz3kLm8x"
      # Old file IDs should be cleared
      assert batch_after_upload.openai_output_file_id == nil
      assert batch_after_upload.openai_error_file_id == nil

      # ════════════════════════════════════════════════════════════════
      # Phase 4: Drain default queue → creates new OpenAI batch
      # ════════════════════════════════════════════════════════════════
      Oban.drain_queue(queue: :default)

      batch_final = Ash.get!(Batching.Batch, batch.id, load: [:transitions])
      assert batch_final.state == :openai_processing
      assert batch_final.openai_batch_id == "batch_newXyz789"

      # Verify the complete transition trail
      transition_pairs =
        batch_final.transitions
        |> Enum.sort_by(& &1.transitioned_at)
        |> Enum.map(fn t -> {t.from, t.to} end)

      assert {:openai_processing, :expired} in transition_pairs
      assert {:expired, :uploading} in transition_pairs
      assert {:uploading, :uploaded} in transition_pairs
      assert {:uploaded, :openai_processing} in transition_pairs

      # Processed requests should still have their responses intact throughout
      success_final = Ash.get!(Batching.Request, success_req.id)
      assert success_final.state == :openai_processed
      assert success_final.response_payload["response"]["body"]["model"] == batch.model
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
