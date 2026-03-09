defmodule Batcher.Batching.Actions.RedeliverFailed do
  @moduledoc """
  Redelivers only failed requests in a batch as one-shot request retries.
  """

  alias Batcher.Batching

  @doc false
  def run(input, _opts, _context) do
    batch_id = input.arguments.id
    batch = Batching.get_batch_by_id!(batch_id)

    Batcher.Batching.Actions.Redeliver.run_for_batch(batch, :failed_only)
  end
end
