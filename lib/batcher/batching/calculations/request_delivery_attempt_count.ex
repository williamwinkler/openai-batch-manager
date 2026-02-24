defmodule Batcher.Batching.Calculations.RequestDeliveryAttemptCount do
  @moduledoc """
  Calculation to count the number of delivery attempts for a request.
  This is done in the application layer for compatibility with existing callers.
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.RequestDeliveryAttempt

  @impl true
  @doc false
  def calculate(records, _opts, _context) do
    # record is a request here
    Enum.map(records, fn record ->
      RequestDeliveryAttempt
      |> Ash.Query.filter(request_id == ^record.id)
      |> Ash.count!()
    end)
  end
end
