defmodule Batcher.Batching.Changes.ApplyTokenLimitBackoff do
  use Ash.Resource.Change

  alias Batcher.Batching.TokenLimitBackoff

  @impl true
  def change(changeset, _opts, _context) do
    current_attempts = Ash.Changeset.get_data(changeset, :token_limit_retry_attempts) || 0
    next_attempt = current_attempts + 1
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset
    |> Ash.Changeset.force_change_attribute(:token_limit_retry_attempts, next_attempt)
    |> Ash.Changeset.force_change_attribute(
      :token_limit_retry_next_at,
      TokenLimitBackoff.next_retry_at(next_attempt, now)
    )
  end
end
