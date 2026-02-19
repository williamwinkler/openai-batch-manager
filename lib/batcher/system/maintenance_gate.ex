defmodule Batcher.System.MaintenanceGate do
  @moduledoc """
  Global runtime gate used to temporarily block intake during maintenance operations.
  """

  @table __MODULE__
  @key :enabled

  @spec enable!() :: :ok
  def enable! do
    ensure_table()
    true = :ets.insert(@table, {@key, true})
    :ok
  end

  @spec disable!() :: :ok
  def disable! do
    ensure_table()
    true = :ets.insert(@table, {@key, false})
    :ok
  end

  @spec enabled?() :: boolean()
  def enabled? do
    ensure_table()

    case :ets.lookup(@table, @key) do
      [{@key, true}] -> true
      _ -> false
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        true = :ets.insert(@table, {@key, false})
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
