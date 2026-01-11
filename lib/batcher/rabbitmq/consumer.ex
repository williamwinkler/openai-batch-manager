defmodule Batcher.RabbitMQ.Consumer do
  @moduledoc """
  GenServer that consumes messages from RabbitMQ and processes them as batch requests.

  Only starts if RABBITMQ_URL and RABBITMQ_INPUT_QUEUE are configured.
  On connection failure, logs error and exits (supervisor will handle restart).

  **Important**: The queue (and optionally exchange) must be pre-created by the developer.
  This consumer will only bind to existing queues/exchanges and consume messages.
  """
  use GenServer
  use AMQP
  require Logger

  alias Batcher.RequestValidator
  alias Batcher.Batching.Handlers.RequestHandler

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    queue = Keyword.fetch!(opts, :queue)
    exchange = Keyword.get(opts, :exchange)
    routing_key = Keyword.get(opts, :routing_key)

    Logger.info("Connecting to RabbitMQ for input consumption: queue=#{queue}")

    case connect_and_setup(url, queue, exchange, routing_key) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        # Raise error to cause supervisor and application to shut down
        raise "RabbitMQ connection failed: #{inspect(reason)}"
    end
  end

  # Confirmation sent by the broker after registering this process as a consumer
  @impl true
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled
  @impl true
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.warning("RabbitMQ consumer cancelled by broker")
    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  @impl true
  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    process_message(payload, meta, state)
    {:noreply, state}
  end

  # Connection or channel died
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("RabbitMQ connection/channel died: #{inspect(reason)}")
    {:stop, {:connection_lost, reason}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn, chan: chan}) do
    # Gracefully close channel and connection to avoid RabbitMQ warnings
    try do
      if Process.alive?(chan.pid), do: Channel.close(chan)
    catch
      _, _ -> :ok
    end

    try do
      if Process.alive?(conn.pid), do: Connection.close(conn)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Private Functions

  defp connect_and_setup(url, queue, exchange, routing_key) do
    case Connection.open(url) do
      {:ok, conn} ->
        Logger.info("Connected to RabbitMQ")
        Process.monitor(conn.pid)

        case Channel.open(conn) do
          {:ok, chan} ->
            Process.monitor(chan.pid)

            # Limit unacknowledged messages to 10
            :ok = Basic.qos(chan, prefetch_count: 10)

            # Bind queue to exchange if both are provided (queue and exchange must exist)
            if exchange && routing_key do
              case Queue.bind(chan, queue, exchange, routing_key: routing_key) do
                :ok ->
                  Logger.info(
                    "Bound queue #{queue} to exchange #{exchange} with routing_key #{routing_key}"
                  )

                {:error, reason} ->
                  Logger.error("Failed to bind queue: #{inspect(reason)}")
                  Connection.close(conn)
                  {:error, {:queue_bind_failed, reason}}
              end
            else
              :ok
            end
            |> case do
              :ok ->
                # Subscribe to queue (will fail if queue doesn't exist)
                case Basic.consume(chan, queue, nil, no_ack: false) do
                  {:ok, _consumer_tag} ->
                    Logger.info("Started consuming from RabbitMQ queue: #{queue}")
                    {:ok, %{conn: conn, chan: chan, queue: queue}}

                  {:error, reason} ->
                    Logger.error("Failed to start consuming from queue: #{inspect(reason)}")
                    Connection.close(conn)
                    {:error, {:consume_failed, reason}}
                end

              {:error, _} = error ->
                error
            end

          {:error, reason} ->
            Logger.error("Failed to open RabbitMQ channel: #{inspect(reason)}")
            Connection.close(conn)
            {:error, {:channel_open_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  defp process_message(payload, %{delivery_tag: tag}, %{chan: chan}) do
    case RequestValidator.validate_json(payload) do
      {:ok, validated} ->
        # Same code path as HTTP from here
        case RequestHandler.handle(validated) do
          {:ok, _request} ->
            Basic.ack(chan, tag)
            Logger.debug("Successfully processed RabbitMQ message")

          {:error, :custom_id_already_taken} ->
            # Processed, just duplicate - ack to remove from queue
            Basic.ack(chan, tag)
            Logger.debug("Duplicate custom_id from RabbitMQ (already processed)")

          {:error, reason} ->
            Logger.error("Failed to process request from RabbitMQ: #{inspect(reason)}")
            Basic.nack(chan, tag, requeue: true)
        end

      {:error, {:invalid_json, reason}} ->
        Logger.error("Invalid JSON from RabbitMQ: #{inspect(reason)}")
        Basic.reject(chan, tag, requeue: false)

      {:error, {:validation_failed, errors}} ->
        Logger.error("Validation failed for RabbitMQ message: #{inspect(errors)}")
        Basic.reject(chan, tag, requeue: false)
    end
  end
end
