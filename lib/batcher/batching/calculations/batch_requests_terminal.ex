defmodule Batcher.Batching.Calculations.BatchRequestsTerminal do
  @moduledoc """
  Calculation to check if all requests in a batch are in terminal states.

  Terminal states are: :delivered, :failed, :expired, :cancelled
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.Request

  @terminal_states [:delivered, :failed, :expired, :cancelled]

  @impl true
  def calculate(records, _opts, _context) do
    # record is a batch here
    Enum.map(records, fn record ->
      # Count requests that are NOT in terminal states
      # If count is 0, all requests are terminal
      non_terminal_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state not in ^@terminal_states)
        |> Ash.count!()

      non_terminal_count == 0
    end)
  end
end
