defmodule Batcher.Batching.Actions.RemediateStuckDownloadsTest do
  use Batcher.DataCase, async: true
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching
  alias Batcher.Repo

  import Batcher.Generator

  describe "remediate_stuck_downloads action" do
    test "re-enqueues processing for stale downloading batches" do
      batch =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()
        |> set_updated_at_seconds_ago(15 * 60 + 1)

      {:ok, returned_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:remediate_stuck_downloads, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert returned_batch.id == batch.id
      assert returned_batch.state == :downloading

      assert_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessDownloadedFile)
    end

    test "fails downloading batches that exceed hard timeout" do
      batch =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: nil
        )
        |> generate()
        |> set_updated_at_seconds_ago(60 * 60 + 1)

      {:ok, failed_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:remediate_stuck_downloads, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert failed_batch.state == :failed
      assert failed_batch.error_msg =~ "Download watchdog timeout"

      refute_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessDownloadedFile)
    end

    test "recovers timed out downloading batches with reconciled work and preserves delivered requests" do
      batch =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      delivered_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :delivered,
            response_payload: %{"ok" => true}
          )
        )

      stuck_request =
        generate(
          seeded_request(
            batch_id: batch.id,
            url: batch.url,
            model: batch.model,
            state: :openai_processing
          )
        )

      batch = set_updated_at_seconds_ago(batch, 60 * 60 + 1)

      {:ok, recovered_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:remediate_stuck_downloads, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert recovered_batch.state == :delivered

      delivered_request_after = Ash.get!(Batching.Request, delivered_request.id)
      stuck_request_after = Ash.get!(Batching.Request, stuck_request.id)

      assert delivered_request_after.batch_id == batch.id
      assert delivered_request_after.state == :delivered
      assert stuck_request_after.batch_id != batch.id
      assert stuck_request_after.state == :pending

      successor_batch = Batching.get_batch_by_id!(stuck_request_after.batch_id)
      assert successor_batch.state == :building
    end

    test "does nothing for fresh downloading batches" do
      batch =
        seeded_batch(
          state: :downloading,
          openai_output_file_id: "file-output-123"
        )
        |> generate()
        |> set_updated_at_seconds_ago(5 * 60)

      {:ok, returned_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:remediate_stuck_downloads, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert returned_batch.id == batch.id
      assert returned_batch.state == :downloading

      refute_enqueued(worker: Batching.Batch.AshOban.Worker.ProcessDownloadedFile)
    end
  end

  defp set_updated_at_seconds_ago(batch, seconds_ago) do
    updated_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    batch
    |> Ecto.Changeset.change(updated_at: updated_at)
    |> Repo.update!()
  end
end
