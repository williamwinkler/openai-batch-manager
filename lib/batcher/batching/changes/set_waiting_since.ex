defmodule Batcher.Batching.Changes.SetWaitingSince do
  @moduledoc """
  Sets waiting_for_capacity_since_at once when entering waiting state.
  """
  use Ash.Resource.Change

  @doc """
  Writes `waiting_for_capacity_since_at` only if it is currently nil, preserving
  the original enqueue timestamp for FIFO fairness.
  """
  @impl true
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_data(changeset, :waiting_for_capacity_since_at)

    if is_nil(current) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :waiting_for_capacity_since_at,
        DateTime.utc_now()
      )
    else
      changeset
    end
  end
end
