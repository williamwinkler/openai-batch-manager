defmodule Batcher.Batching.TokenLimitBackoff do
  @moduledoc """
  Deterministic backoff policy for OpenAI token-limit retry attempts.
  """

  @delays_minutes [5, 10, 20, 40, 80]

  @spec delay_minutes_for_attempt(pos_integer()) :: pos_integer() | nil
  def delay_minutes_for_attempt(attempt) when is_integer(attempt) and attempt > 0 do
    Enum.at(@delays_minutes, attempt - 1)
  end

  def delay_minutes_for_attempt(_), do: nil

  @spec next_retry_at(pos_integer(), DateTime.t()) :: DateTime.t() | nil
  def next_retry_at(attempt, now \\ DateTime.utc_now()) do
    case delay_minutes_for_attempt(attempt) do
      nil -> nil
      minutes -> DateTime.add(now, minutes * 60, :second)
    end
  end
end
