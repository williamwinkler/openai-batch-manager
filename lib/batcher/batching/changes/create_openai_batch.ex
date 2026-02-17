defmodule Batcher.Batching.Changes.CreateOpenaiBatch do
  use Ash.Resource.Change
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.CapacityControl

  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data

    latest_batch = Batching.get_batch_by_id!(batch.id)

    valid_state? =
      latest_batch.state in [:uploaded, :waiting_for_capacity] or
        (latest_batch.state == :expired and is_nil(latest_batch.openai_output_file_id) and
           is_nil(latest_batch.openai_error_file_id))

    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      cond do
        not valid_state? ->
          Logger.info(
            "Skipping create_openai_batch for batch #{batch.id}, invalid state #{inspect(latest_batch.state)}"
          )

          Ash.Changeset.add_error(
            changeset,
            "Batch #{batch.id} is no longer in a state that can create an OpenAI batch (current state: #{latest_batch.state})"
          )

        is_nil(latest_batch.openai_input_file_id) ->
          Ash.Changeset.add_error(
            changeset,
            "Batch #{batch.id} has no input file id for OpenAI batch creation"
          )

        true ->
          case CapacityControl.decision(latest_batch) do
            {:admit, _ctx} ->
              # Create batch on OpenAI before transaction starts in case it fails
              case Batcher.OpenaiApiClient.create_batch(
                     latest_batch.openai_input_file_id,
                     batch.url
                   ) do
                {:ok, response} ->
                  changeset
                  |> Ash.Changeset.force_change_attribute(:openai_batch_id, response["id"])
                  |> Ash.Changeset.force_change_attribute(
                    :capacity_last_checked_at,
                    DateTime.utc_now()
                  )
                  |> Ash.Changeset.force_change_attribute(:capacity_wait_reason, nil)

                {:error, {:bad_request, body}} ->
                  if token_limit_exceeded?(body) do
                    move_to_waiting(latest_batch, "token_limit_exceeded")

                    Ash.Changeset.add_error(
                      changeset,
                      "Batch #{batch.id} is waiting for OpenAI queue headroom"
                    )
                  else
                    message = Map.get(body, "error", %{}) |> Map.get("message", "Bad request")
                    Ash.Changeset.add_error(changeset, "OpenAI batch creation failed: #{message}")
                  end

                {:error, reason} ->
                  error_msg =
                    case reason do
                      atom when is_atom(atom) -> "OpenAI batch creation failed: #{atom}"
                      other -> "OpenAI batch creation failed: #{inspect(other)}"
                    end

                  Ash.Changeset.add_error(changeset, error_msg)
              end

            {:wait_capacity_blocked, _ctx} ->
              move_to_waiting(latest_batch, "insufficient_headroom")
              Ash.Changeset.add_error(changeset, "Batch waiting for capacity")
          end
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, batch ->
      # Bulk update all pending requests to processing after transaction
      Batcher.Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.filter(state == :pending)
      |> Ash.bulk_update!(:bulk_begin_processing, %{}, strategy: :stream)

      {:ok, batch}
    end)
  end

  defp move_to_waiting(batch, reason) do
    if batch.state in [:uploaded, :expired] do
      _ = Batching.wait_for_capacity(batch, %{capacity_wait_reason: reason})
    else
      _ = Batching.touch_waiting_for_capacity(batch, %{capacity_wait_reason: reason})
    end
  end

  defp token_limit_exceeded?(body) when is_map(body) do
    errors = get_in(body, ["errors", "data"]) || []
    error = body["error"] || %{}

    Enum.any?(errors, fn row -> row["code"] == "token_limit_exceeded" end) or
      error["code"] == "token_limit_exceeded"
  end

  defp token_limit_exceeded?(_), do: false
end
