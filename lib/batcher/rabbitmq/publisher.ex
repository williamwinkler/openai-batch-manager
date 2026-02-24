defmodule Batcher.RabbitMQ.Publisher do
  @moduledoc """
  Public RabbitMQ publisher API.

  Keeps a stable module/process name for callers while routing publishes
  through a partitioned pool of publisher workers.
  """
  use GenServer

  @doc """
  Starts the publisher facade and worker pool.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish a message to a RabbitMQ destination.
  """
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, routing_key, payload, opts}, 10_000)
  end

  @doc """
  Clear cached destination status for one destination.
  """
  def clear_destination_cache(exchange, routing_key) do
    GenServer.cast(__MODULE__, {:clear_cache, exchange, routing_key})
  end

  @doc """
  Clear all cached destination statuses across the pool.
  """
  def clear_all_cache do
    GenServer.cast(__MODULE__, :clear_all_cache)
  end

  @doc """
  Returns true if the publisher facade process is running.
  """
  def started? do
    Process.whereis(__MODULE__) != nil
  end

  @doc """
  Returns true if at least one worker reports an active connection.
  """
  def connected? do
    if started?() do
      GenServer.call(__MODULE__, :connected?)
    else
      false
    end
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    {:ok, _pid} = Batcher.RabbitMQ.PublisherPool.start_link(opts)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:publish, exchange, routing_key, payload, opts}, _from, state) do
    reply = Batcher.RabbitMQ.PublisherPool.publish(exchange, routing_key, payload, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, Batcher.RabbitMQ.PublisherPool.connected?(), state}
  end

  @impl true
  def handle_cast({:clear_cache, exchange, routing_key}, state) do
    Batcher.RabbitMQ.PublisherPool.clear_destination_cache(exchange, routing_key)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_all_cache, state) do
    Batcher.RabbitMQ.PublisherPool.clear_all_cache()
    {:noreply, state}
  end
end
