defmodule Batcher.RabbitMQ.Publisher do
  @moduledoc """
  GenServer that publishes messages to RabbitMQ queues/exchanges.

  Maintains a single persistent connection to RabbitMQ and caches destination
  validation results to avoid repeatedly checking for non-existent queues/exchanges.

  Features:
  - Lazy connection: connects on first publish if not already connected
  - Destination caching: remembers validated and failed destinations
  - Failure TTL: cached failures expire after 5 minutes to allow retry
  - Publisher confirms: ensures reliable delivery acknowledgment
  - Auto-reconnection: reconnects if connection dies
  """
  use GenServer
  use AMQP
  require Logger

  @failure_cache_ttl_ms :timer.minutes(5)
  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000

  ## Client API

  @doc """
  Starts the Publisher GenServer.

  Options:
  - `:url` (required) - RabbitMQ connection URL
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish a message to a RabbitMQ destination.

  Args:
  - `exchange` - Exchange name (empty string "" for default exchange)
  - `routing_key` - Routing key (or queue name for default exchange)
  - `payload` - Message payload (will be JSON encoded)
  - `opts` - Additional AMQP publish options

  Returns:
  - `:ok` on success
  - `{:error, :not_connected}` if RabbitMQ connection is down
  - `{:error, :queue_not_found}` if queue doesn't exist (cached)
  - `{:error, :exchange_not_found}` if exchange doesn't exist (cached)
  - `{:error, :timeout}` if publisher confirm times out
  - `{:error, reason}` for other failures
  """
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, routing_key, payload, opts}, 10_000)
  end

  @doc """
  Clear the cache for a specific destination, allowing retry.

  Useful if a queue/exchange was created after a previous failure.
  """
  def clear_destination_cache(exchange, routing_key) do
    GenServer.cast(__MODULE__, {:clear_cache, {exchange, routing_key}})
  end

  @doc """
  Clear all destination caches.
  """
  def clear_all_cache do
    GenServer.cast(__MODULE__, :clear_all_cache)
  end

  @doc """
  Returns whether the publisher is currently connected to RabbitMQ.
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
    Logger.info("Starting RabbitMQ Publisher...")

    case connect(url) do
      {:ok, conn, chan} ->
        Logger.info("RabbitMQ Publisher started and connected")
        broadcast_status(:connected)

        {:ok,
         %{
           url: url,
           conn: conn,
           chan: chan,
           destinations: %{},
           backoff_ms: @initial_backoff_ms,
           reconnect_ref: nil
         }}

      {:error, reason} ->
        Logger.error("Publisher failed to connect to RabbitMQ: #{inspect(reason)}")
        Logger.info("Publisher will retry connection in #{@initial_backoff_ms}ms")
        broadcast_status(:disconnected)
        ref = Process.send_after(self(), :reconnect, @initial_backoff_ms)

        {:ok,
         %{
           url: url,
           conn: nil,
           chan: nil,
           destinations: %{},
           backoff_ms: @initial_backoff_ms,
           reconnect_ref: ref
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.conn != nil && state.chan != nil, state}
  end

  @impl true
  def handle_call({:publish, exchange, routing_key, payload, opts}, _from, state) do
    destination = {exchange, routing_key}
    destination_str = format_destination(exchange, routing_key)

    Logger.info("Publishing message to RabbitMQ: #{destination_str}")

    case ensure_connected(state) do
      {:ok, state} ->
        case check_destination_cache(state, destination) do
          {:cached_failure, reason} ->
            # Return cached failure immediately - don't retry
            Logger.info("Using cached failure for #{destination_str}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}

          :ok_or_unknown ->
            # Either validated before, or first time seeing this destination
            case do_publish(state, exchange, routing_key, payload, opts) do
              :ok ->
                # Mark destination as validated
                state = put_destination(state, destination, :validated)
                Logger.info("Successfully published message to #{destination_str}")
                {:reply, :ok, state}

              {:error, reason} = error ->
                # Cache the failure with timestamp
                state = put_destination(state, destination, {:failed, reason, now()})

                Logger.warning(
                  "Failed to publish message to #{destination_str}: #{inspect(reason)}"
                )

                # If channel might have closed during validation, clear it so it gets recreated
                state =
                  if state.chan && !Process.alive?(state.chan.pid) do
                    Logger.warning("Channel died during validation, clearing channel reference")
                    %{state | chan: nil}
                  else
                    state
                  end

                {:reply, error, state}
            end
        end

      {:error, reason} ->
        Logger.error("Cannot publish to #{destination_str}: not connected to RabbitMQ")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:clear_cache, {exchange, routing_key}}, state) do
    destination_str = format_destination(exchange, routing_key)
    destinations = Map.delete(state.destinations, {exchange, routing_key})
    Logger.info("Cleared cache for destination: #{destination_str}")
    {:noreply, %{state | destinations: destinations}}
  end

  @impl true
  def handle_cast(:clear_all_cache, state) do
    cache_size = map_size(state.destinations)
    Logger.info("Cleared all destination caches (#{cache_size} entries)")
    {:noreply, %{state | destinations: %{}}}
  end

  # Handle connection/channel death
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      state.conn && state.conn.pid == pid ->
        Logger.warning("Publisher connection died: #{inspect(reason)}")
        broadcast_status(:disconnected)
        ref = Process.send_after(self(), :reconnect, state.backoff_ms)
        {:noreply, %{state | conn: nil, chan: nil, reconnect_ref: ref}}

      state.chan && state.chan.pid == pid ->
        Logger.warning("Publisher channel died: #{inspect(reason)}")
        broadcast_status(:disconnected)
        ref = Process.send_after(self(), :reconnect, state.backoff_ms)
        {:noreply, %{state | chan: nil, reconnect_ref: ref}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect, %{conn: conn} = state) when conn != nil do
    # Already reconnected (e.g., via a publish call), skip
    {:noreply, %{state | reconnect_ref: nil}}
  end

  def handle_info(:reconnect, state) do
    Logger.info("Publisher attempting to reconnect to RabbitMQ...")

    case connect(state.url) do
      {:ok, conn, chan} ->
        Logger.info("Publisher successfully reconnected to RabbitMQ")
        broadcast_status(:connected)

        {:noreply,
         %{state | conn: conn, chan: chan, backoff_ms: @initial_backoff_ms, reconnect_ref: nil}}

      {:error, reason} ->
        next_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
        Logger.error("Publisher failed to reconnect to RabbitMQ: #{inspect(reason)}")
        Logger.info("Publisher will retry in #{next_backoff}ms")
        ref = Process.send_after(self(), :reconnect, next_backoff)
        {:noreply, %{state | backoff_ms: next_backoff, reconnect_ref: ref}}
    end
  end

  # Handle returned (unroutable) messages
  @impl true
  def handle_info({:basic_return, _payload, %{routing_key: rk, exchange: ex}}, state) do
    Logger.warning("Message returned as unroutable: exchange=#{ex} routing_key=#{rk}")
    # Could update cache here, but the publish already failed
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## Private Functions

  defp connect(url) do
    with {:ok, conn} <- Connection.open(url),
         {:ok, chan} <- Channel.open(conn) do
      Process.monitor(conn.pid)
      Process.monitor(chan.pid)

      # Enable publisher confirms for reliability
      :ok = Confirm.select(chan)

      # Register return handler for unroutable messages
      :ok = Basic.return(chan, self())

      Logger.info("Publisher connected to RabbitMQ")
      {:ok, conn, chan}
    end
  end

  defp ensure_connected(%{conn: nil, url: url} = state) do
    Logger.info("Attempting to connect to RabbitMQ...")

    case connect(url) do
      {:ok, conn, chan} ->
        Logger.info("Successfully connected to RabbitMQ")
        broadcast_status(:connected)
        cancel_reconnect_timer(state)

        {:ok,
         %{state | conn: conn, chan: chan, backoff_ms: @initial_backoff_ms, reconnect_ref: nil}}

      {:error, reason} ->
        Logger.error("Failed to connect to RabbitMQ: #{inspect(reason)}")
        {:error, :not_connected}
    end
  end

  defp ensure_connected(%{conn: conn, chan: chan} = state) do
    cond do
      !Process.alive?(conn.pid) ->
        # Connection died, clear it and retry
        Logger.warning("Connection to RabbitMQ died, attempting to reconnect...")
        ensure_connected(%{state | conn: nil, chan: nil})

      chan == nil || !Process.alive?(chan.pid) ->
        # Channel died but connection is alive, recreate channel
        Logger.warning("Channel to RabbitMQ died, recreating channel...")

        case Channel.open(conn) do
          {:ok, new_chan} ->
            Process.monitor(new_chan.pid)
            # Re-enable publisher confirms
            :ok = Confirm.select(new_chan)
            # Re-register return handler
            :ok = Basic.return(new_chan, self())
            Logger.info("Successfully recreated RabbitMQ channel")
            {:ok, %{state | chan: new_chan}}

          {:error, reason} ->
            Logger.error("Failed to recreate channel: #{inspect(reason)}")
            {:error, :channel_failed}
        end

      true ->
        {:ok, state}
    end
  end

  defp check_destination_cache(state, destination) do
    case Map.get(state.destinations, destination) do
      :validated ->
        Logger.debug("Destination validated (cached), skipping validation")
        :ok_or_unknown

      {:failed, reason, failed_at} ->
        if cache_expired?(failed_at) do
          # Cache expired, allow retry
          Logger.debug("Cache expired for failed destination, retrying...")
          :ok_or_unknown
        else
          {:cached_failure, reason}
        end

      nil ->
        Logger.debug("First time seeing destination, validating...")
        :ok_or_unknown
    end
  end

  defp do_publish(state, exchange, routing_key, payload, opts) do
    chan = state.chan
    destination_str = format_destination(exchange, routing_key)

    # First, validate the destination exists
    with :ok <- validate_destination(chan, exchange, routing_key) do
      Logger.debug("Destination validated: #{destination_str}")

      # Extract custom_id for logging before encoding
      custom_id = Map.get(payload, "custom_id") || Map.get(payload, :custom_id) || "unknown"

      encoded_payload = JSON.encode!(payload)
      Logger.debug("Publishing message to #{destination_str}")

      # Publish with mandatory flag to catch unroutable messages
      # Set content_type and content_encoding for proper message metadata
      publish_opts =
        Keyword.merge(
          [
            persistent: true,
            mandatory: true,
            content_type: "application/json",
            content_encoding: "utf-8"
          ],
          opts
        )

      case Basic.publish(chan, exchange, routing_key, encoded_payload, publish_opts) do
        :ok ->
          # Wait for publisher confirm
          case Confirm.wait_for_confirms(chan, 5_000) do
            true ->
              Logger.debug(
                "Publisher confirm received for request #{custom_id} to #{destination_str}"
              )

              :ok

            false ->
              Logger.warning("Publisher nack received for #{destination_str}")
              {:error, :nack}

            :timeout ->
              Logger.warning("Publisher confirm timeout for #{destination_str}")
              {:error, :timeout}
          end

        error ->
          Logger.error("Failed to publish to #{destination_str}: #{inspect(error)}")
          error
      end
    else
      error ->
        Logger.warning("Destination validation failed for #{destination_str}: #{inspect(error)}")
        error
    end
  end

  defp validate_destination(chan, "" = _exchange, queue) do
    # Direct queue publish (default exchange) - check queue exists
    try do
      case Queue.declare(chan, queue, passive: true) do
        {:ok, _info} -> :ok
        {:error, _} -> {:error, :queue_not_found}
      end
    rescue
      # Channel closes on passive declare of non-existent queue
      _ -> {:error, :queue_not_found}
    catch
      # Also catch exits in case channel closes
      :exit, _ -> {:error, :queue_not_found}
    end
  end

  defp validate_destination(chan, exchange, _routing_key) do
    # Named exchange - check exchange exists
    try do
      case Exchange.declare(chan, exchange, :direct, passive: true) do
        :ok -> :ok
        {:error, _} -> {:error, :exchange_not_found}
      end
    rescue
      _ -> {:error, :exchange_not_found}
    catch
      # Also catch exits in case channel closes
      :exit, _ -> {:error, :exchange_not_found}
    end
  end

  defp put_destination(state, destination, status) do
    %{state | destinations: Map.put(state.destinations, destination, status)}
  end

  defp cache_expired?(failed_at) do
    DateTime.diff(now(), failed_at, :millisecond) > @failure_cache_ttl_ms
  end

  defp now, do: DateTime.utc_now()

  defp format_destination("", routing_key) do
    "queue=#{routing_key}"
  end

  defp format_destination(exchange, routing_key) do
    "exchange=#{exchange} routing_key=#{routing_key}"
  end

  defp cancel_reconnect_timer(%{reconnect_ref: nil}), do: :ok

  defp cancel_reconnect_timer(%{reconnect_ref: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  defp broadcast_status(status) do
    try do
      Phoenix.PubSub.broadcast(
        Batcher.PubSub,
        "rabbitmq:status",
        {:rabbitmq_status, %{process: :publisher, status: status}}
      )
    catch
      _, _ -> :ok
    end
  end
end
