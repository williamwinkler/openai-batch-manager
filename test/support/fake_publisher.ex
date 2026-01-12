defmodule Batcher.RabbitMQ.FakePublisher do
  @moduledoc """
  Fake Publisher GenServer for testing RabbitMQ delivery without requiring a real RabbitMQ instance.

  Usage in tests:
  ```elixir
  # Success case
  {:ok, _pid} = Batcher.RabbitMQ.FakePublisher.start_link()

  # Error case
  {:ok, _pid} = Batcher.RabbitMQ.FakePublisher.start_link(
    responses: %{{"", "my_queue"} => {:error, :queue_not_found}}
  )
  ```

  The fake publisher is registered under the same name as the real Publisher,
  so it can be used as a drop-in replacement in tests.
  """
  use GenServer

  ## Client API

  @doc """
  Starts the Fake Publisher GenServer.

  Options:
  - `:responses` - Map of `{exchange, routing_key}` tuples to response values.
                   Defaults to `%{}` which means all publishes return `:ok`.
                   Use `{:error, reason}` for error responses.
  """
  def start_link(opts \\ []) do
    responses = Keyword.get(opts, :responses, %{})
    default_response = Keyword.get(opts, :default_response, :ok)

    # Register under the same name as the real Publisher so it can be used as a drop-in replacement
    GenServer.start_link(__MODULE__, {responses, default_response},
      name: Batcher.RabbitMQ.Publisher
    )
  end

  @doc """
  Publish a message (same interface as real Publisher).
  """
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(
      Batcher.RabbitMQ.Publisher,
      {:publish, exchange, routing_key, payload, opts},
      10_000
    )
  end

  @doc """
  Clear the cache for a specific destination (same interface as real Publisher).
  """
  def clear_destination_cache(exchange, routing_key) do
    GenServer.cast(Batcher.RabbitMQ.Publisher, {:clear_cache, {exchange, routing_key}})
  end

  @doc """
  Clear all destination caches (same interface as real Publisher).
  """
  def clear_all_cache do
    GenServer.cast(Batcher.RabbitMQ.Publisher, :clear_all_cache)
  end

  ## Server Callbacks

  @impl true
  def init({responses, default_response}) do
    {:ok, %{responses: responses, default_response: default_response}}
  end

  @impl true
  def handle_call({:publish, exchange, routing_key, _payload, _opts}, _from, state) do
    destination = {exchange, routing_key}
    response = Map.get(state.responses, destination, state.default_response)
    {:reply, response, state}
  end

  @impl true
  def handle_cast({:clear_cache, _destination}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_all_cache, state) do
    {:noreply, state}
  end
end
