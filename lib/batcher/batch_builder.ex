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
  @metrics_delta_topic "batches:metrics_delta"

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

  Batch rotation decisions are based on structured Ash validation reasons emitted
  by `BatchCanAcceptRequest` (`private_vars[:reason]`) with temporary message
  fallback for compatibility.
  """
  def add_request(url, model, request_data, retries \\ 5) do
    case Registry.lookup(Batcher.BatchRegistry, {url, model}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:add_request, request_data}, 30_000)
          |> maybe_retry_batch_rotation(url, model, request_data, retries)
        catch
          # If the BatchBuilder exited between the lookup and the call, retry
          :exit, _ -> add_request(url, model, request_data, retries)
        end

      [] ->
        # Start new BatchBuilder (uses restart: :temporary so it won't auto-restart)
        result =
          DynamicSupervisor.start_child(Batcher.BatchSupervisor, {__MODULE__, {url, model}})

        case result do
          {:ok, pid} ->
            GenServer.call(pid, {:add_request, request_data}, 30_000)
            |> maybe_retry_batch_rotation(url, model, request_data, retries)

          {:error, {:already_started, pid}} ->
            GenServer.call(pid, {:add_request, request_data}, 30_000)
            |> maybe_retry_batch_rotation(url, model, request_data, retries)

          {:error, reason} ->
            # Check if this is a transient database error and retry
            if transient_db_error?(reason) and retries > 0 do
              Logger.warning(
                "Transient database error starting BatchBuilder, retrying... (#{retries} retries left)"
              )

              Process.sleep(200)
              add_request(url, model, request_data, retries - 1)
            else
              Logger.error(
                "Failed to start BatchBuilder for url=#{url} model=#{model}: #{inspect(reason)}"
              )

              {:error, {:batch_builder_start_failed, reason}}
            end
        end
    end
  end

  # Check if the error is a transient database error (e.g., SQLite database busy)
  defp transient_db_error?({{:badmatch, {:error, %Ash.Error.Unknown{} = error}}, _stack}) do
    Enum.any?(error.errors, fn err ->
      is_binary(Map.get(err, :error)) and String.contains?(err.error, "Database busy")
    end)
  end

  defp transient_db_error?(_), do: false

  # During rollover the old builder may return transient states while it stops.
  # Retry to target the new builder/batch.
  defp maybe_retry_batch_rotation({:error, reason}, url, model, request_data, retries)
       when reason in [:batch_full, :batch_not_building] and retries > 0 do
    Process.sleep(25)
    add_request(url, model, request_data, retries - 1)
  end

  defp maybe_retry_batch_rotation(
         {:error, %Ash.Error.Invalid{} = error},
         url,
         model,
         request_data,
         retries
       )
       when retries > 0 do
    if transient_batch_reference_error?(error) do
      Process.sleep(25)
      add_request(url, model, request_data, retries - 1)
    else
      {:error, error}
    end
  end

  defp maybe_retry_batch_rotation(result, _url, _model, _request_data, _retries), do: result

  defp transient_batch_reference_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Query.NotFound{resource: Batcher.Batching.Batch} ->
        true

      %{field: :batch_id} = err ->
        batch_error_reason(err) == :batch_not_found or
          (is_binary(Map.get(err, :message)) and
             String.contains?(err.message, "batch not found"))

      _ ->
        false
    end)
  end

  defp batch_error_reason(%{private_vars: vars}) when is_map(vars), do: Map.get(vars, :reason)

  defp batch_error_reason(%{private_vars: vars}) when is_list(vars),
    do: Keyword.get(vars, :reason)

  defp batch_error_reason(%{vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp batch_error_reason(%{vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)

  defp batch_error_reason(_), do: nil

  defp batch_rotation_reason?(reason) when reason in [:batch_full, :batch_size_would_exceed],
    do: true

  defp batch_rotation_reason?(_), do: false

  defp batch_rotation_required_error?(%{field: :batch_id} = err) do
    reason = batch_error_reason(err)
    message = Map.get(err, :message)

    batch_rotation_reason?(reason) or
      (is_binary(message) and
         (String.contains?(message, "Batch is full") or String.contains?(message, "would exceed")))
  end

  defp batch_rotation_required_error?(_), do: false

  @doc """
  Force upload of the current batch (marks ready for upload).

  If a BatchBuilder process exists for this url/model, it will be used.
  If no process exists (e.g., after server restart), a new BatchBuilder
  will be started to handle the upload.
  """
  def upload_batch(url, model) do
    case Registry.lookup(Batcher.BatchRegistry, {url, model}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :finish_building, 30_000)
        catch
          :exit, _ -> start_and_upload(url, model)
        end

      [] ->
        start_and_upload(url, model)
    end
  end

  defp start_and_upload(url, model) do
    # First check if there's actually a building batch to upload
    case Batcher.Batching.find_building_batch(model, url) do
      {:ok, _batch} ->
        # Start a new BatchBuilder (it will find the existing building batch)
        case DynamicSupervisor.start_child(Batcher.BatchSupervisor, {__MODULE__, {url, model}}) do
          {:ok, pid} ->
            GenServer.call(pid, :finish_building, 30_000)

          {:error, {:already_started, pid}} ->
            GenServer.call(pid, :finish_building, 30_000)

          {:error, reason} ->
            Logger.error("Failed to start BatchBuilder for upload: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, _} ->
        {:error, :no_building_batch}
    end
  end

  ## Server Callbacks

  @max_prompts 50_000

  @impl true
  def init({url, model}) do
    batch = get_building_batch(url, model)

    if batch.request_count >= @max_prompts do
      raise "BatchBuilder initialized but batch is already full"
    end

    Logger.info(
      "BatchBuilder initialized for batch #{batch.id}: #{url} - #{model} - requests=#{batch.request_count} size=#{Format.bytes(batch.size_bytes)}"
    )

    BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch.id}")
    BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch.id}")

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
  def handle_call(:terminate, _from, state) do
    Logger.info("BatchBuilder [#{state.batch_id}] terminating due to batch deletion")
    Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
    state = Map.put(state, :terminating, true)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call({:add_request, request_data}, _from, state) do
    add_request_to_batch(request_data, state)
  end

  defp add_request_to_batch(request_data, state) do
    # Create Prompt record via internal action
    request_data = Map.put(request_data, :batch_id, state.batch_id)

    delivery_config =
      Map.get(request_data, :delivery_config)
      |> stringify_keys()

    case Batcher.Batching.create_request(%{
           batch_id: state.batch_id,
           custom_id: request_data.custom_id,
           url: request_data.url,
           model: request_data.body.model,
           delivery_config: delivery_config,
           request_payload: request_data
         }) do
      {:ok, request} ->
        publish_batch_metrics_delta(request)

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

        # Check if this requires rotating to a new batch (count full or size overflow)
        needs_batch_rotation = Enum.any?(error.errors, &batch_rotation_required_error?/1)
        stale_batch_reference = transient_batch_reference_error?(error)

        cond do
          is_duplicate ->
            Logger.warning("Duplicate custom_id attempted",
              custom_id: request_data.custom_id,
              batch_id: state.batch_id
            )

            {:reply, {:error, :custom_id_already_taken}, state}

          stale_batch_reference ->
            Logger.warning(
              "Batch #{state.batch_id} no longer exists, rotating BatchBuilder to a new batch"
            )

            Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
            state = Map.put(state, :terminating, true)
            {:stop, :normal, {:error, :batch_not_building}, state}

          needs_batch_rotation ->
            Logger.info(
              "Batch #{state.batch_id} reached capacity, triggering upload and shutting down"
            )

            # Batch is full - trigger upload, unregister, and stop so a new BatchBuilder can be created
            trigger_upload_and_stop(state)

          true ->
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

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "batches:destroyed:" <> _batch_id,
          payload: _notification
        },
        state
      ) do
    # Skip termination if we're already terminating (prevents double termination)
    if state.terminating do
      Logger.debug(
        "BatchBuilder [#{state.batch_id}] received destroy notification but already terminating, skipping"
      )

      {:noreply, state}
    else
      Logger.info("BatchBuilder [#{state.batch_id}] stopping. Batch was destroyed")

      # Unregister before terminating
      Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
      state = Map.put(state, :terminating, true)
      {:stop, :normal, state}
    end
  end

  ## Private Functions

  # When batch is full, trigger upload, unregister, and stop so retry creates a new BatchBuilder
  defp trigger_upload_and_stop(state) do
    # Unregister first so new requests don't hit this dying process
    Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})
    state = Map.put(state, :terminating, true)

    # Trigger the upload in background (don't block the caller)
    spawn(fn ->
      case Batcher.Batching.get_batch_by_id(state.batch_id) do
        {:ok, batch} ->
          case Batcher.Batching.start_batch_upload(batch) do
            {:ok, _} ->
              Logger.info(
                "BatchBuilder [#{state.batch_id}] batch upload started after becoming full"
              )

            {:error, error} ->
              Logger.error(
                "BatchBuilder [#{state.batch_id}] failed to start upload after becoming full: #{inspect(error)}"
              )
          end

        {:error, error} ->
          Logger.error(
            "BatchBuilder [#{state.batch_id}] failed to get batch for upload: #{inspect(error)}"
          )
      end
    end)

    # Reply with :batch_full and stop - the caller will retry and create a new BatchBuilder
    {:stop, :normal, {:error, :batch_full}, state}
  end

  defp get_building_batch(url, model) do
    case Batcher.Batching.find_building_batch(model, url) do
      {:ok, existing_batch} ->
        Logger.info(
          "BatchBuilder reusing existing building batch: url=#{url} model=#{model} batch_id=#{existing_batch.id}"
        )

        existing_batch

      {:error, _} ->
        # No draft batch found, create a new one
        {:ok, new_batch} = Batcher.Batching.create_batch(model, url)

        Logger.info(
          "BatchBuilder created new batch: url=#{url} model=#{model} batch_id=#{new_batch.id}"
        )

        new_batch
    end
  end

  defp via_tuple(url, model) do
    {:via, Registry, {Batcher.BatchRegistry, {url, model}}}
  end

  defp publish_batch_metrics_delta(request) do
    BatcherWeb.Endpoint.broadcast(
      @metrics_delta_topic,
      "delta",
      %{
        batch_id: request.batch_id,
        request_count_delta: 1,
        size_bytes_delta: request.request_payload_size,
        ts: DateTime.utc_now()
      }
    )
  end

  defp stringify_keys(struct) when is_struct(struct) do
    # Convert struct to plain map (removing __struct__ key), then stringify
    struct
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = to_string(k)
      # Convert enum atom values to strings (e.g., :webhook -> "webhook")
      value = if k == :type and is_atom(v), do: to_string(v), else: v
      {key, value}
    end)
  end
end
