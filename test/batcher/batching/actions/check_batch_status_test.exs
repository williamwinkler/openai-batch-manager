defmodule Batcher.Batching.Actions.CheckBatchStatusTest do
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

  describe "check_batch_status action" do
    test "transitions to openai_completed when status is completed", %{server: server} do
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
        "request_counts" => %{"completed" => 471, "failed" => 0, "total" => 471},
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
      assert batch_after.openai_requests_completed == 471
      assert batch_after.openai_requests_failed == 0
      assert batch_after.openai_requests_total == 471

      # Verify transition record
      assert length(batch_after.transitions) == 1
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :openai_completed
    end

    test "transitions to failed when status is failed", %{server: server} do
      openai_batch_id = "batch_failed123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "failed",
        "request_counts" => %{"completed" => 33, "failed" => 11, "total" => 44},
        "error" => %{
          "message" => "Batch processing failed",
          "code" => "batch_failed"
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :failed
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_requests_completed == 33
      assert batch_after.openai_requests_failed == 11
      assert batch_after.openai_requests_total == 44

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :failed
    end

    test "token_limit_exceeded moves batch back to waiting_for_capacity with retry backoff", %{
      server: server
    } do
      openai_batch_id = "batch_token_limit_123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          token_limit_retry_attempts: 0
        )
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch_before.id,
            state: :openai_processing,
            error_msg: "old error",
            response_payload: %{"foo" => "bar"}
          )
        )

      response = %{
        "status" => "failed",
        "errors" => %{
          "data" => [
            %{
              "code" => "token_limit_exceeded",
              "message" => "Enqueued token limit reached"
            }
          ]
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])
      request_after = Ash.get!(Batching.Request, request.id)

      assert batch_after.state == :waiting_for_capacity
      assert batch_after.capacity_wait_reason == "token_limit_exceeded_backoff"
      assert batch_after.token_limit_retry_attempts == 1
      assert batch_after.token_limit_retry_next_at
      assert batch_after.token_limit_retry_last_error
      assert batch_after.openai_batch_id == nil
      assert batch_after.openai_status_last_checked_at == nil

      assert request_after.state == :pending
      assert request_after.error_msg == nil
      assert request_after.response_payload == nil

      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :waiting_for_capacity
    end

    test "token_limit_exceeded fails terminally after max retries exhausted", %{server: server} do
      openai_batch_id = "batch_token_limit_exhausted_123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          token_limit_retry_attempts: 5
        )
        |> generate()

      response = %{
        "status" => "failed",
        "errors" => %{
          "data" => [
            %{
              "code" => "token_limit_exceeded",
              "message" => "Enqueued token limit reached"
            }
          ]
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :failed
      assert batch_after.token_limit_retry_attempts == 5
      assert batch_after.token_limit_retry_next_at == nil
      assert batch_after.error_msg =~ "retries exhausted"
    end

    test "transitions to expired and reschedules when status is expired with no file IDs", %{
      server: server
    } do
      openai_batch_id = "batch_expired123"
      openai_input_file_id = "file-1quwTNE3rPZezkuRuGuXaS"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: openai_input_file_id
        )
        |> generate()

      # Ensure batch has at least one request (use seeded_request to bypass state validation)
      generate(
        seeded_request(
          batch_id: batch_before.id,
          url: batch_before.url,
          model: batch_before.model
        )
      )

      # Mock the expired status check with NO file IDs
      expired_response = %{
        "status" => "expired"
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", expired_response, 200)

      # Mock the new batch creation (using existing file ID)
      new_batch_response = %{
        "id" => "batch_new123",
        "status" => "validating",
        "input_file_id" => openai_input_file_id
      }

      expect_json_response(server, :post, "/v1/batches", new_batch_response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Immediately after mark_expired, batch is in :expired state
      assert batch_after.state == :expired
      # These are unset when marking as expired
      assert batch_after.openai_status_last_checked_at == nil
      assert batch_after.expires_at == nil
      assert batch_after.openai_batch_id == nil

      # Drain the capacity dispatch queue to process capacity-aware dispatch and OpenAI batch creation
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
      Oban.drain_queue(queue: :capacity_dispatch)

      # Reload the batch to see the final state
      batch_final = Ash.get!(Batching.Batch, batch_after.id, load: [:transitions])

      assert batch_final.state == :openai_processing
      assert batch_final.openai_batch_id == "batch_new123"

      # Verify transition records - should have at least 2 transitions:
      # 1. openai_processing → expired
      # 2. expired → openai_processing
      assert length(batch_final.transitions) >= 2
      transitions = Enum.sort_by(batch_final.transitions, & &1.transitioned_at)

      # Find the specific transitions we care about (in case there are others)
      expired_transition =
        Enum.find(transitions, fn t -> t.from == :openai_processing and t.to == :expired end)

      assert expired_transition != nil,
             "Expected transition from :openai_processing to :expired, got transitions: #{inspect(transitions)}"

      resumed_transition =
        Enum.find(transitions, fn t -> t.from == :expired and t.to == :openai_processing end)

      assert resumed_transition != nil,
             "Expected transition from :expired to :openai_processing, got transitions: #{inspect(transitions)}"

      # Verify the expired transition happened before the resumed transition
      assert DateTime.compare(
               expired_transition.transitioned_at,
               resumed_transition.transitioned_at
             ) != :gt
    end

    test "transitions to expired with partial results when output_file_id is present", %{
      server: server
    } do
      openai_batch_id = "batch_expired_partial123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: "file-input123"
        )
        |> generate()

      # Mock the expired status check WITH output_file_id
      expired_response = %{
        "status" => "expired",
        "output_file_id" => "file-partial-output123",
        "error_file_id" => "file-partial-error123"
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", expired_response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should use handle_partial_expiration instead of mark_expired
      assert batch_after.state == :expired
      assert batch_after.openai_output_file_id == "file-partial-output123"
      assert batch_after.openai_error_file_id == "file-partial-error123"
      assert batch_after.openai_batch_id == nil
      assert batch_after.openai_status_last_checked_at == nil
      assert batch_after.expires_at == nil

      # Should enqueue process_expired_batch job
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessExpiredBatch)
    end

    test "transitions to expired with partial results when only error_file_id is present", %{
      server: server
    } do
      openai_batch_id = "batch_expired_error_only123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_input_file_id: "file-input456"
        )
        |> generate()

      # Mock the expired status check with only error_file_id
      expired_response = %{
        "status" => "expired",
        "error_file_id" => "file-error-only456"
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", expired_response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :expired
      assert batch_after.openai_output_file_id == nil
      assert batch_after.openai_error_file_id == "file-error-only456"

      # Should enqueue process_expired_batch job
      assert_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessExpiredBatch)
    end

    test "updates last_checked_at without state change when status is pending", %{server: server} do
      openai_batch_id = "batch_pending123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "validating",
        "request_counts" => %{"completed" => 417, "failed" => 0, "total" => 471}
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # State should remain unchanged
      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_status_last_checked_at != nil
      assert batch_after.openai_requests_completed == 417
      assert batch_after.openai_requests_failed == 0
      assert batch_after.openai_requests_total == 471
    end

    test "updates last_checked_at when pending counts are unchanged", %{server: server} do
      openai_batch_id = "batch_pending_unchanged123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_requests_completed: 20,
          openai_requests_failed: 1,
          openai_requests_total: 25
        )
        |> generate()

      response = %{
        "status" => "in_progress",
        "request_counts" => %{"completed" => 20, "failed" => 1, "total" => 25}
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_requests_completed == 20
      assert batch_after.openai_requests_failed == 1
      assert batch_after.openai_requests_total == 25
    end

    test "ignores malformed request_counts values", %{server: server} do
      openai_batch_id = "batch_pending_malformed123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_requests_completed: 9,
          openai_requests_failed: 2,
          openai_requests_total: 11
        )
        |> generate()

      response = %{
        "status" => "in_progress",
        "request_counts" => %{"completed" => "nine", "failed" => -1, "total" => "eleven"}
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_requests_completed == 9
      assert batch_after.openai_requests_failed == 2
      assert batch_after.openai_requests_total == 11
    end

    test "handles missing request_counts without resetting existing values", %{server: server} do
      openai_batch_id = "batch_pending_missing_counts123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id,
          openai_requests_completed: 100,
          openai_requests_failed: 4,
          openai_requests_total: 120
        )
        |> generate()

      response = %{"status" => "finalizing"}

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.state == :openai_processing
      assert batch_after.openai_status_last_checked_at
      assert batch_after.openai_requests_completed == 100
      assert batch_after.openai_requests_failed == 4
      assert batch_after.openai_requests_total == 120
    end

    test "handles API failures gracefully", %{server: server} do
      openai_batch_id = "batch_error123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock API failure
      expect_json_response(
        server,
        :get,
        "/v1/batches/#{openai_batch_id}",
        %{"error" => "Not found"},
        404
      )

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      # Should return error
      assert {:error, _} = result
    end

    test "extracts and assigns token usage correctly", %{server: server} do
      openai_batch_id = "batch_tokens123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      response = %{
        "status" => "completed",
        "output_file_id" => "file-output123",
        "usage" => %{
          "input_tokens" => 5000,
          "input_tokens_details" => %{"cached_tokens" => 1000},
          "output_tokens_details" => %{"reasoning_tokens" => 500},
          "output_tokens" => 2000
        }
      }

      expect_json_response(server, :get, "/v1/batches/#{openai_batch_id}", response, 200)

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_batch_status, %{})
        |> Map.put(:subject, batch_before)
        |> Ash.run_action()

      assert batch_after.input_tokens == 5000
      assert batch_after.cached_tokens == 1000
      assert batch_after.reasoning_tokens == 500
      assert batch_after.output_tokens == 2000
    end
  end
end
