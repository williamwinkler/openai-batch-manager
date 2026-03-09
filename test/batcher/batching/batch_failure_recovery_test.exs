defmodule Batcher.Batching.BatchFailureRecoveryTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  defp assert_has_transition!(transitions, from, to) do
    assert Enum.any?(transitions, fn transition ->
             transition.from == from and transition.to == to
           end)
  end

  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
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

  describe "Batcher.Batching.Batch.handle_download_error" do
    test "transitions batch from downloading to failed" do
      batch_before =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:handle_download_error, %{error: "download failed"})
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :failed
      assert batch_after.error_msg == "Failed while processing downloaded batch files"
      assert_has_transition!(batch_after.transitions, :downloading, :failed)
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
      transitions = Enum.sort_by(batch_final.transitions, &{&1.transitioned_at, &1.id})
      recent_transitions = Enum.take(transitions, -2)
      assert_has_transition!(recent_transitions, :openai_processing, :expired)
      assert_has_transition!(recent_transitions, :expired, :openai_processing)
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
