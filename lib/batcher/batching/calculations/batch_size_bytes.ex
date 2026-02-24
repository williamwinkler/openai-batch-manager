defmodule Batcher.Batching.Calculations.BatchSizeBytes do
  @moduledoc """
  Calculation to sum the total size in bytes of all requests in a batch.
  This is done in the application layer for compatibility with existing callers.
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.Request

  @impl true
  @doc false
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      Request
      |> Ash.Query.filter(batch_id == ^record.id)
      |> Ash.sum!(:request_payload_size)
    end)
  end
end
