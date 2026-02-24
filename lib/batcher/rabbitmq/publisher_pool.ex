defmodule Batcher.RabbitMQ.PublisherPool do
  @moduledoc """
  Partitioned pool for RabbitMQ publisher workers.

  Routes by `{exchange, routing_key}` to preserve per-destination ordering while
  allowing parallel publishing across destinations.
  """
  require Logger

  @name __MODULE__

  def start_link(opts) do
    pool_size =
      Keyword.get(
        opts,
        :pool_size,
        Application.get_env(:batcher, :rabbitmq_publisher_pool_size, 4)
      )

    PartitionSupervisor.start_link(
      child_spec: {Batcher.RabbitMQ.PublisherWorker, opts},
      name: @name,
      partitions: pool_size
    )
  end

  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(
      worker_name(exchange, routing_key),
      {:publish, exchange, routing_key, payload, opts},
      10_000
    )
  catch
    :exit, reason ->
      Logger.error("Publisher worker call failed: #{inspect(reason)}")
      {:error, :not_connected}
  end

  def clear_destination_cache(exchange, routing_key) do
    GenServer.cast(worker_name(exchange, routing_key), {:clear_cache, {exchange, routing_key}})
  end

  def clear_all_cache do
    @name
    |> Supervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        GenServer.cast(pid, :clear_all_cache)

      _ ->
        :ok
    end)

    :ok
  end

  def connected? do
    @name
    |> Supervisor.which_children()
    |> Enum.any?(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        try do
          GenServer.call(pid, :connected?)
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end)
  rescue
    _ -> false
  end

  defp worker_name(exchange, routing_key) do
    {:via, PartitionSupervisor, {@name, {exchange, routing_key}}}
  end
end
