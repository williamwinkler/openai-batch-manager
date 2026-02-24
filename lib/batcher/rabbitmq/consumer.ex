defmodule Batcher.RabbitMQ.Consumer do
  @moduledoc """
  GenServer that consumes messages from RabbitMQ and processes them as batch requests.

  Only starts if RABBITMQ_URL and RABBITMQ_INPUT_QUEUE are configured.
  On connection failure, enters disconnected state and retries with exponential backoff.

  ## Configuration

  Consume directly from a queue:

      RABBITMQ_URL=amqp://user:pass@host:5672
      RABBITMQ_INPUT_QUEUE=my-queue

  **Important**: The queue must be pre-created by the developer.
  This consumer will only consume from existing queues.
  """
  use GenServer
  use AMQP
  require Logger

  alias Batcher.Batching.Validation.RequestValidator
  alias Batcher.Batching.Handlers.RequestHandler
  alias Batcher.System.MaintenanceGate

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns whether the consumer is currently connected to RabbitMQ.
  Returns false if the process is not running.
  """
  def connected? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid when is_pid(pid) -> GenServer.call(pid, :connected?)
    end
  catch
    :exit, _ -> false
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    queue = Keyword.fetch!(opts, :queue)
    Logger.info("RabbitMQ consumer starting: queue=#{queue}")

    state = %{
      url: url,
      queue: queue,
      conn: nil,
      chan: nil,
      backoff_ms: @initial_backoff_ms,
      reconnect_ref: nil
    }

    case connect_and_setup(url, queue) do
      {:ok, conn_state} ->
        broadcast_status(:connected)
        {:ok, Map.merge(state, conn_state) |> Map.put(:backoff_ms, @initial_backoff_ms)}

      {:error, reason} ->
        Logger.error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        Logger.info("Consumer will retry connection in #{@initial_backoff_ms}ms")
        broadcast_status(:disconnected)
        ref = schedule_reconnect(@initial_backoff_ms)
        {:ok, %{state | reconnect_ref: ref}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.conn != nil && state.chan != nil, state}
  end

  # Confirmation sent by the broker after registering this process as a consumer
  @impl true
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled
  @impl true
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.warning("RabbitMQ consumer cancelled by broker, will reconnect")
    state = cleanup_connection(state)
    broadcast_status(:disconnected)
    ref = schedule_reconnect(state.backoff_ms)
    {:noreply, %{state | reconnect_ref: ref}}
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
    state = cleanup_connection(state)
    broadcast_status(:disconnected)
    ref = schedule_reconnect(state.backoff_ms)
    {:noreply, %{state | reconnect_ref: ref}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to RabbitMQ...")

    case connect_and_setup(state.url, state.queue) do
      {:ok, conn_state} ->
        Logger.info("Successfully reconnected to RabbitMQ")
        broadcast_status(:connected)

        {:noreply,
         Map.merge(state, conn_state)
         |> Map.put(:backoff_ms, @initial_backoff_ms)
         |> Map.put(:reconnect_ref, nil)}

      {:error, reason} ->
        next_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
        Logger.error("Failed to reconnect to RabbitMQ: #{inspect(reason)}")
        Logger.info("Consumer will retry in #{next_backoff}ms")
        ref = schedule_reconnect(next_backoff)
        {:noreply, %{state | backoff_ms: next_backoff, reconnect_ref: ref}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn, chan: chan}) when not is_nil(conn) or not is_nil(chan) do
    try do
      if chan && Process.alive?(chan.pid), do: Channel.close(chan)
    catch
      _, _ -> :ok
    end

    try do
      if conn && Process.alive?(conn.pid), do: Connection.close(conn)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Private Functions

  defp connect_and_setup(url, queue) do
    case Connection.open(url) do
      {:ok, conn} ->
        Logger.info("Connected to RabbitMQ")
        Process.monitor(conn.pid)

        case Channel.open(conn) do
          {:ok, chan} ->
            Process.monitor(chan.pid)

            # Limit unacknowledged messages to 10
            :ok = Basic.qos(chan, prefetch_count: 10)

            # Subscribe to queue (will fail if queue doesn't exist)
            try do
              case Basic.consume(chan, queue, nil, no_ack: false) do
                {:ok, _consumer_tag} ->
                  Logger.info("Started consuming from RabbitMQ queue: #{queue}")
                  {:ok, %{conn: conn, chan: chan}}

                {:error, reason} ->
                  Logger.error("Failed to start consuming from queue: #{inspect(reason)}")
                  safely_close_connection(conn)
                  {:error, {:consume_failed, reason}}
              end
            catch
              :exit, reason ->
                Logger.error("Failed to consume from queue (exit): #{inspect(reason)}")
                safely_close_connection(conn)
                {:error, {:consume_failed, reason}}
            end

          {:error, reason} ->
            Logger.error("Failed to open RabbitMQ channel: #{inspect(reason)}")
            safely_close_connection(conn)
            {:error, {:channel_open_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  defp process_message(payload, %{delivery_tag: tag}, %{chan: chan}) do
    case decide_message_action(payload) do
      :ack ->
        Basic.ack(chan, tag)

      {:nack, requeue} ->
        Basic.nack(chan, tag, requeue: requeue)

      {:reject, requeue} ->
        Basic.reject(chan, tag, requeue: requeue)
    end
  end

  @doc false
  def decide_message_action(
        payload,
        validator \\ RequestValidator,
        request_handler \\ RequestHandler,
        gate \\ MaintenanceGate
      ) do
    if gate.enabled?() do
      Logger.warning("Maintenance mode enabled, requeuing RabbitMQ intake message")
      {:nack, true}
    else
      case validator.validate_json(payload) do
        {:ok, validated} ->
          # Same code path as HTTP from here
          case request_handler.handle(validated) do
            {:ok, _request} ->
              Logger.debug("Successfully processed RabbitMQ message")
              :ack

            {:error, :custom_id_already_taken} ->
              # Processed, just duplicate - ack to remove from queue
              Logger.debug("Duplicate custom_id from RabbitMQ (already processed)")
              :ack

            {:error, reason} ->
              Logger.error("Failed to process request from RabbitMQ: #{inspect(reason)}")
              {:nack, true}
          end

        {:error, {:invalid_json, reason}} ->
          Logger.error("Invalid JSON from RabbitMQ: #{inspect(reason)}")
          {:reject, false}

        {:error, {:validation_failed, errors}} ->
          Logger.error("Validation failed for RabbitMQ message: #{inspect(errors)}")
          {:reject, false}
      end
    end
  end

  defp safely_close_connection(conn) do
    try do
      if Process.alive?(conn.pid), do: Connection.close(conn)
    catch
      _, _ -> :ok
    end
  end

  defp cleanup_connection(state) do
    try do
      if state.chan && Process.alive?(state.chan.pid), do: Channel.close(state.chan)
    catch
      _, _ -> :ok
    end

    try do
      if state.conn && Process.alive?(state.conn.pid), do: Connection.close(state.conn)
    catch
      _, _ -> :ok
    end

    %{state | conn: nil, chan: nil}
  end

  defp schedule_reconnect(delay_ms) do
    Process.send_after(self(), :reconnect, delay_ms)
  end

  defp broadcast_status(status) do
    try do
      Phoenix.PubSub.broadcast(
        Batcher.PubSub,
        "rabbitmq:status",
        {:rabbitmq_status, %{process: :consumer, status: status}}
      )
    catch
      _, _ -> :ok
    end
  end
end
