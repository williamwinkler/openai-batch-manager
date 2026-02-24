defmodule Batcher.Batching.RecoveryTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  describe "resume_stale_work/0" do
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
  end
end
