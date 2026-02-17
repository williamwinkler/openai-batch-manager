defmodule Batcher.Batching.Calculations.BatchProcessingSince do
  @moduledoc """
  Returns the timestamp when the batch most recently entered the :openai_processing state,
  by looking up the latest matching transition record.
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.BatchTransition

  @impl true
  def calculate(records, _opts, _context) do
    batch_ids = Enum.map(records, & &1.id)

    timestamps =
      BatchTransition
      |> Ash.Query.filter(batch_id in ^batch_ids and to == :openai_processing)
      |> Ash.Query.sort(transitioned_at: :desc)
      |> Ash.read!()
      |> Enum.group_by(& &1.batch_id)
      |> Map.new(fn {batch_id, transitions} ->
        {batch_id, List.first(transitions).transitioned_at}
      end)

    Enum.map(records, fn record ->
      Map.get(timestamps, record.id)
    end)
  end
end
