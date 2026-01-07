defmodule Batcher.BatchBuilder do
  @moduledoc """
  GenServer that aggregates requests into batches.

  One BatchBuilder runs per {url, model} combination. When the batch reaches
  capacity (50k requests) or time limit (1 hour), it marks the batch ready for upload
  and shuts down. New requests will create a new BatchBuilder for that combination.

  ## Configuration

  See config.exs for:
  - max_requests: Maximum requests per batch
  - max_age_hours: Maximum age before marking ready
  - check_interval_minutes: How often to check if ready

  ## Registry

  BatchBuilders are registered in `Batcher.BatchRegistry` with key `{url, model}`.
  """
  use GenServer, restart: :temporary
  require Logger

  require Ash.Query
  alias Batcher.Utils.Format

  ## Client API

  @doc """
  Starts a BatchBuilder for the given url and model combination.
  """
  def start_link({url, model}) do
    GenServer.start_link(__MODULE__, {url, model}, name: via_tuple(url, model))
  end

  @doc """
  Add a request to the batch for this url/model combination.

  Returns:
  - `{:ok, request}` - Prompt successfully added
  - `{:error, :batch_full}` - Batch is full, retry will create new batch
  - `{:error, reason}` - Failed to create request
  """
  def add_request(url, model, request_data) do
    case Registry.lookup(Batcher.BatchRegistry, {url, model}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:add_request, request_data}, 30_000)
        catch
          # If the BatchBuilder exited between the lookup and the call, retry
          :exit, _ -> add_request(url, model, request_data)
        end

      [] ->
        # Start new BatchBuilder (uses restart: :temporary so it won't auto-restart)
        result =
          DynamicSupervisor.start_child(Batcher.BatchSupervisor, {__MODULE__, {url, model}})

        case result do
          {:ok, pid} ->
            GenServer.call(pid, {:add_request, request_data}, 30_000)

          {:error, {:already_started, pid}} ->
            GenServer.call(pid, {:add_request, request_data}, 30_000)
        end
    end
  end

  @doc """
  Force upload of the current batch (marks ready for upload).
  """
  def upload_batch(url, model) do
    GenServer.call(via_tuple(url, model), :finish_building, 30_000)
  end

  ## Server Callbacks

  @impl true
  def init({url, model}) do
    batch = get_building_batch(url, model)

    if batch.request_count >= 50_000 do
      raise "BatchBuilder initialized but batch is already full"
    end

    Logger.info(
      "BatchBuilder initialized for batch #{batch.id}: #{url} - #{model} - requests=#{batch.request_count} size=#{Format.bytes(batch.size_bytes)}"
    )

    BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch.id}")

    {:ok,
     %{
       batch_id: batch.id,
       url: url,
       model: model,
       terminating: false
     }}
  end

  @impl true
  def handle_call(:finish_building, _from, state) do
    Logger.info("BatchBuilder [#{state.batch_id}] marking batch ready for upload")

    case Batcher.Batching.get_batch_by_id(state.batch_id) do
      {:ok, batch} ->
        # Set terminating flag to prevent double termination from PubSub
        state = Map.put(state, :terminating, true)

        case Batcher.Batching.start_batch_upload(batch) do
          {:ok, _updated_batch} ->
            Logger.info("BatchBuilder [#{state.batch_id}] batch marked for upload, shutting down")
            Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
            {:stop, :normal, :ok, state}

          {:error, error} ->
            Logger.error(
              "BatchBuilder [#{state.batch_id}] failed to start upload: #{inspect(error)}"
            )

            Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
            {:stop, :normal, {:error, error}, state}
        end

      {:error, error} ->
        Logger.error("BatchBuilder [#{state.batch_id}] failed to get batch: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:add_request, request_data}, _from, state) do
    # Verify batch is still in building state before adding requests
    case Batcher.Batching.get_batch_by_id(state.batch_id) do
      {:ok, batch} ->
        if batch.state != :building do
          Logger.warning(
            "BatchBuilder [#{state.batch_id}] received request but batch is in #{batch.state} state, shutting down"
          )

          # Unregister before terminating
          Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
          state = Map.put(state, :terminating, true)
          {:stop, :normal, {:error, :batch_not_building}, state}
        else
          add_request_to_batch(request_data, state)
        end

      {:error, error} ->
        Logger.error("BatchBuilder [#{state.batch_id}] failed to get batch: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  defp add_request_to_batch(request_data, state) do
    # Create Prompt record via internal action
    request_data = Map.put(request_data, :batch_id, state.batch_id)

    case Batcher.Batching.create_request(%{
           batch_id: state.batch_id,
           custom_id: request_data.custom_id,
           url: request_data.url,
           model: request_data.body.model,
           delivery: request_data.delivery,
           request_payload: request_data
         }) do
      {:ok, request} ->
        Logger.debug(
          "[Batch #{state.batch_id}] Request added successfully with custom_id=#{request.custom_id}"
        )

        {:reply, {:ok, request}, state}

      {:error, %Ash.Error.Invalid{} = error} ->
        # Check if this is a unique constraint violation on custom_id
        is_duplicate =
          Enum.any?(error.errors, fn err ->
            err.field == :custom_id and String.contains?(err.message, "already been taken")
          end)

        if is_duplicate do
          Logger.warning("Duplicate custom_id attempted",
            custom_id: request_data.custom_id,
            batch_id: state.batch_id
          )

          {:reply, {:error, :custom_id_already_taken}, state}
        else
          Logger.error(
            "Failed to create request in database: #{inspect(error, pretty: true, limit: :infinity)}"
          )

          {:reply, {:error, error}, state}
        end

      {:error, error} ->
        Logger.error(
          "Failed to create request in database: #{inspect(error, pretty: true, limit: :infinity)}"
        )

        {:reply, {:error, error}, state}
    end
  end

  @doc """
  Handles notifications about batch state changes.
  If the batch is no longer in 'building' state, the BatchBuilder shuts down.
  """
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "batches:state_changed:" <> _batch_id,
          payload: notification
        },
        state
      ) do
    # Skip termination if we're already terminating (prevents double termination)
    if state.terminating do
      Logger.debug(
        "BatchBuilder [#{state.batch_id}] received state change notification but already terminating, skipping"
      )

      {:noreply, state}
    else
      batch = notification.data

      if batch.state != :building do
        Logger.info(
          "BatchBuilder [#{state.batch_id}] stopping. Batch state is now #{batch.state}"
        )

        # Unregister before terminating
        Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
        state = Map.put(state, :terminating, true)
        {:stop, :normal, state}
      else
        {:noreply, state}
      end
    end
  end

  ## Private Functions
  defp get_building_batch(url, model) do
    case Batcher.Batching.find_building_batch(model, url, load: [:request_count, :size_bytes]) do
      {:ok, existing_batch} ->
        Logger.info(
          "BatchBuilder reusing existing building batch: url=#{url} model=#{model} batch_id=#{existing_batch.id}"
        )

        existing_batch

      {:error, _} ->
        # No draft batch found, create a new one
        {:ok, new_batch} = Batcher.Batching.create_batch(model, url)

        # Load calculations for logging
        new_batch = Ash.load!(new_batch, [:request_count, :size_bytes])

        Logger.info(
          "BatchBuilder created new batch: url=#{url} model=#{model} batch_id=#{new_batch.id}"
        )

        new_batch
    end
  end

  defp via_tuple(url, model) do
    {:via, Registry, {Batcher.BatchRegistry, {url, model}}}
  end
end
