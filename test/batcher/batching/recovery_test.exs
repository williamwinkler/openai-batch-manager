defmodule Batcher.Batching.RecoveryTest do
  use Batcher.DataCase, async: true
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  describe "resume_stale_work/0" do
    test "re-enqueues dispatch for uploaded batches" do
      _batch =
        seeded_batch(
          state: :uploaded,
          openai_input_file_id: "file-input-123"
        )
        |> generate()

      :ok = Batcher.Batching.Recovery.resume_stale_work()

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
    end

    test "re-enqueues dispatch for waiting_for_capacity batches" do
      _batch =
        seeded_batch(
          state: :waiting_for_capacity,
          openai_input_file_id: "file-input-123",
          waiting_for_capacity_since_at: DateTime.utc_now()
        )
        |> generate()

      :ok = Batcher.Batching.Recovery.resume_stale_work()

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.DispatchWaitingForCapacity)
    end

    test "re-enqueues processing for downloading batches" do
      _batch =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      :ok = Batcher.Batching.Recovery.resume_stale_work()

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessDownloadedFile)
    end

    test "re-enqueues start_downloading for openai_completed batches" do
      _batch =
        seeded_batch(
          state: :openai_completed,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      :ok = Batcher.Batching.Recovery.resume_stale_work()

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.StartDownloading)
    end

    test "re-enqueues start_delivering for ready_to_deliver batches" do
      _batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      :ok = Batcher.Batching.Recovery.resume_stale_work()

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.StartDelivering)
    end
  end
end
