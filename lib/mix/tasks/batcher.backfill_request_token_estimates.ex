defmodule Mix.Tasks.Batcher.BackfillRequestTokenEstimates do
  @shortdoc "Backfills request and batch token estimate columns"

  use Mix.Task

  alias Batcher.Repo
  alias Batcher.TokenEstimation.RequestEstimator

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {updated_requests, failed_requests} = backfill_requests()
    backfill_batch_totals()

    Mix.shell().info("Backfill complete")
    Mix.shell().info("Updated requests: #{updated_requests}")
    Mix.shell().info("Failed requests: #{failed_requests}")
  end

  defp backfill_requests do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT id, url, model, request_payload FROM requests ORDER BY id ASC", [])

    Enum.reduce(rows, {0, 0}, fn [id, url, model, request_payload], {updated, failed} ->
      try do
        {:ok, %{request_tokens: request_tokens, capacity_tokens: capacity_tokens}} =
          RequestEstimator.estimate(url, model, request_payload)

        Repo.query!(
          """
          UPDATE requests
          SET
            estimated_request_input_tokens = ?1,
            estimated_input_tokens = ?2
          WHERE id = ?3
          """,
          [request_tokens, capacity_tokens, id]
        )

        {updated + 1, failed}
      rescue
        error ->
          Mix.shell().error("Failed to estimate request #{id}: #{inspect(error)}")
          {updated, failed + 1}
      end
    end)
  end

  defp backfill_batch_totals do
    Repo.query!(
      """
      UPDATE batches
      SET
        request_count = (
          SELECT COUNT(*)
          FROM requests
          WHERE requests.batch_id = batches.id
        ),
        estimated_input_tokens_total = COALESCE((
          SELECT SUM(estimated_input_tokens)
          FROM requests
          WHERE requests.batch_id = batches.id
        ), 0),
        estimated_request_input_tokens_total = COALESCE((
          SELECT SUM(estimated_request_input_tokens)
          FROM requests
          WHERE requests.batch_id = batches.id
        ), 0),
        size_bytes = COALESCE((
          SELECT SUM(request_payload_size)
          FROM requests
          WHERE requests.batch_id = batches.id
        ), 0)
      """,
      []
    )
  end
end
