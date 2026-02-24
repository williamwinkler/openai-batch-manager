defmodule BatcherWeb.Live.Utils.ActionActivity do
  @moduledoc """
  Shared in-flight action tracking for LiveViews.

  Uses ETS for single-node coordination and broadcasts lifecycle updates so
  other LiveViews can re-render loading states immediately.
  """

  @table :batcher_live_action_activity
  @default_ttl_ms 120_000

  @type action_key :: tuple()
  @type scope :: {:batch, integer()} | {:request, integer()} | :settings

  @spec start(action_key(), Keyword.t()) :: :ok | :already_running
  def start(key, opts \\ []) do
    ensure_table()
    cleanup_expired()

    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    scope = Keyword.get(opts, :scope)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    if :ets.insert_new(@table, {key, expires_at}) do
      maybe_broadcast(scope, key, :started)
      :ok
    else
      :already_running
    end
  end

  @spec finish(action_key(), Keyword.t()) :: :ok
  def finish(key, opts \\ []) do
    ensure_table()
    :ets.delete(@table, key)

    scope = Keyword.get(opts, :scope)
    maybe_broadcast(scope, key, :finished)
    :ok
  end

  @spec active?(action_key()) :: boolean()
  def active?(key) do
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

  @spec subscribe(scope()) :: :ok | {:error, term()}
  def subscribe(scope), do: BatcherWeb.Endpoint.subscribe(topic(scope))

  @spec unsubscribe(scope()) :: :ok
  def unsubscribe(scope), do: BatcherWeb.Endpoint.unsubscribe(topic(scope))

  defp topic({:batch, id}), do: "ui_actions:batch:#{id}"
  defp topic({:request, id}), do: "ui_actions:request:#{id}"
  defp topic(:settings), do: "ui_actions:settings"

  defp maybe_broadcast(nil, _key, _state), do: :ok

  defp maybe_broadcast(scope, key, state) do
    BatcherWeb.Endpoint.broadcast(topic(scope), "changed", %{key: key, state: state})
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
