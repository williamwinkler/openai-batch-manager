defmodule BatcherWeb.Live.Utils.ActionLocks do
  @moduledoc false

  @table :batcher_live_action_locks
  @default_ttl_ms 120_000

  @spec acquire(term(), non_neg_integer()) :: boolean()
  def acquire(key, ttl_ms \\ @default_ttl_ms) do
    ensure_table()
    cleanup_expired()

    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert_new(@table, {key, expires_at})
  end

  @spec release(term()) :: true
  def release(key) do
    ensure_table()
    :ets.delete(@table, key)
  end

  @spec locked?(term()) :: boolean()
  def locked?(key) do
    ensure_table()

    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, expires_at}] when expires_at > now ->
        true

      [{^key, _expired_at}] ->
        :ets.delete(@table, key)
        false

      [] ->
        false
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {
        {:"$1", :"$2"},
        [{:<, :"$2", now}],
        [true]
      }
    ])
  end
end
