defmodule Batcher.Batching.Actions.Redeliver do
  @moduledoc """
  Redelivers requests in a batch as one-shot request retries.
  """
  alias Ecto.Adapters.SQL
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.Changes.EnqueuePendingDeliveries
  alias Batcher.Repo

  @all_redeliverable_states [
    "openai_processed",
    "delivered",
    "failed",
    "delivery_failed",
    "expired",
    "cancelled"
  ]

  @doc false
  def run(input, _opts, _context) do
    batch_id = input.arguments.id
    batch = Batching.get_batch_by_id!(batch_id)

    run_for_batch(batch, :all_deliverable)
  end

  @doc false
  def run_for_batch(batch, mode) do
    label = mode_label(mode)

    if batch.state == :delivering do
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           %Ash.Error.Changes.InvalidAttribute{
             field: :state,
             message: "Batch is already delivering"
           }
         ]
       )}
    else
      deliverable_count = count_redeliverable_requests(batch.id, mode)
      queued_count = count_queued_requests(batch.id, mode)

      Logger.info(
        "Redelivering #{label} for batch #{batch.id}: found #{deliverable_count} requests (#{queued_count} already queued)"
      )

      if deliverable_count == 0 do
        Logger.info("Batch #{batch.id} has no #{label} requests to redeliver")
        {:ok, batch}
      else
        with {:ok, batch_after_state_update} <- maybe_resume_batch_delivery(batch) do
          updated_count = reset_requests_for_redelivery(batch.id, mode)
          EnqueuePendingDeliveries.enqueue_pending_deliveries(batch_after_state_update)

          Logger.info(
            "Batch #{batch.id} redelivery initiated for #{updated_count} #{label} requests"
          )

          if updated_count != deliverable_count do
            Logger.warning(
              "Batch #{batch.id} redelivery count mismatch: expected #{deliverable_count}, updated #{updated_count}"
            )
          end

          {:ok, batch_after_state_update}
        end
      end
    end
  end

  defp count_redeliverable_requests(batch_id, :all_deliverable) do
    query = """
    SELECT COUNT(*)::bigint
    FROM requests
    WHERE batch_id = $1
      AND response_payload IS NOT NULL
      AND state = ANY($2)
    """

    %{rows: [[count]]} = SQL.query!(Repo, query, [batch_id, @all_redeliverable_states])
    count
  end

  defp count_redeliverable_requests(batch_id, :failed_only) do
    query = """
    SELECT COUNT(*)::bigint
    FROM requests
    WHERE batch_id = $1
      AND response_payload IS NOT NULL
      AND state = 'delivery_failed'
    """

    %{rows: [[count]]} = SQL.query!(Repo, query, [batch_id])
    count
  end

  defp count_queued_requests(batch_id, :all_deliverable) do
    query = """
    SELECT COUNT(*)::bigint
    FROM requests
    WHERE batch_id = $1
      AND response_payload IS NOT NULL
      AND state = 'openai_processed'
    """

    %{rows: [[count]]} = SQL.query!(Repo, query, [batch_id])
    count
  end

  defp count_queued_requests(_batch_id, :failed_only), do: 0

  defp reset_requests_for_redelivery(batch_id, :all_deliverable) do
    query = """
    UPDATE requests
    SET state = 'openai_processed',
        updated_at = (NOW() AT TIME ZONE 'utc')
    WHERE batch_id = $1
      AND response_payload IS NOT NULL
      AND state = ANY($2)
    """

    %{num_rows: num_rows} = SQL.query!(Repo, query, [batch_id, @all_redeliverable_states])
    num_rows
  end

  defp reset_requests_for_redelivery(batch_id, :failed_only) do
    query = """
    UPDATE requests
    SET state = 'openai_processed',
        updated_at = (NOW() AT TIME ZONE 'utc')
    WHERE batch_id = $1
      AND response_payload IS NOT NULL
      AND state = 'delivery_failed'
    """

    %{num_rows: num_rows} = SQL.query!(Repo, query, [batch_id])
    num_rows
  end

  defp mode_label(:all_deliverable), do: "deliverable"
  defp mode_label(:failed_only), do: "failed deliverable"

  defp maybe_resume_batch_delivery(%{state: state} = batch)
       when state in [:delivered, :partially_delivered, :delivery_failed] do
    batch
    |> Ash.Changeset.for_update(:resume_delivering)
    |> Ash.update()
  end

  defp maybe_resume_batch_delivery(batch), do: {:ok, batch}
end
