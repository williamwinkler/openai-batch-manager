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
  use GenServer
  require Logger

  require Ash.Query
  alias Batcher.Batching.{BatchLimits, BatchQueries}
  alias Batcher.Utils.Format

  @max_requests BatchLimits.max_requests_per_batch()
  @max_age_hours 1

  ## Client API

  @doc """
  Starts a BatchBuilder for the given url and model combination.
  """
  def start_link({url, model}) do
    GenServer.start_link(__MODULE__, {url, model}, name: via_tuple(url, model))
  end

  def start_link({url, model, opts}) when is_list(opts) do
    GenServer.start_link(__MODULE__, {url, model, opts}, name: via_tuple(url, model))
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
        GenServer.call(pid, {:add_request, request_data}, 30_000)

      [] ->
        # Start new BatchBuilder
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Batcher.BatchSupervisor,
            {__MODULE__, {url, model}}
          )

        GenServer.call(pid, {:add_request, request_data}, 30_000)
    end
  end

  @doc """
  Force upload of the current batch (marks ready for upload).
  """
  def upload_batch(url, model) do
    GenServer.cast(via_tuple(url, model), :finish_building)
  end

  ## Server Callbacks

  @impl true
  def init({url, model}) do
    init({url, model, []})
  end

  def init({url, model, _opts}) do
    batch = get_batch(url, model)

    # Count existing requests and sum their sizes to maintain accurate state
    request_count = BatchQueries.count_requests_in_batch(batch.id)
    total_size_bytes = BatchQueries.sum_request_sizes_in_batch(batch.id)

    Logger.info(
      "BatchBuilder initialized: batch_id=#{batch.id} existing_requests=#{request_count} total_size=#{Format.bytes(total_size_bytes)}"
    )

    # Schedule periodic check
    schedule_expiry()

    {:ok,
     %{
       batch_id: batch.id,
       url: url,
       model: model,
       request_count: request_count,
       total_size_bytes: total_size_bytes,
       started_at: DateTime.utc_now(),
       status: :building
     }}
  end

  @impl true
  def handle_call({:add_request, request_data}, _from, state) do
    cond do
      state.status != :building ->
        {:reply, {:error, :batch_full}, state}

      state.request_count >= @max_requests ->
        finish_building(state)
        {:reply, {:error, :batch_full}, state}

      true ->
        # Compute the size of this request to check if it fits
        # (The Ash change will compute it again, but we need it now for the check)
        # TODO: rely on ash?
        request_size = BatchQueries.compute_payload_size(request_data.request_payload)
        new_total_size = state.total_size_bytes + request_size

        # Check if adding this request would exceed 200 MB limit
        if new_total_size > BatchLimits.max_batch_size_bytes() do
          Logger.info(
            "Batch #{state.batch_id} size limit reached. Current: #{Format.bytes(state.total_size_bytes)}, request: #{Format.bytes(request_size)}, would be: #{Format.bytes(new_total_size)}"
          )

          finish_building(state)
          {:reply, {:error, :batch_full}, state}
        else
          # Create Prompt record via internal action
          full_data = Map.put(request_data, :batch_id, state.batch_id)

          Logger.debug(
            "Creating new request"
          )

          # Turn the request_payload into a JSON string
          full_data = Map.update!(full_data, :request_payload, &JSON.encode!/1)

          case Batcher.Batching.create_request(full_data) do
            {:ok, request} ->
              new_state = %{
                state
                | request_count: state.request_count + 1,
                  total_size_bytes: state.total_size_bytes + request.request_payload_size
              }

              Logger.debug(
                "[Batch #{state.batch_id}] Prompt created successfully. Total requests: #{new_state.request_count}, total size: #{Format.bytes(new_state.total_size_bytes)}"
              )

              # Check if should mark ready (don't block the caller)
              if should_mark_ready?(new_state) do
                spawn(fn -> finish_building(new_state) end)
              end

              {:reply, {:ok, request}, new_state}

            {:error, %Ash.Error.Invalid{} = error} ->
              # Check if this is a unique constraint violation on custom_id
              is_duplicate =
                Enum.any?(error.errors, fn err ->
                  err.field == :custom_id and String.contains?(err.message, "already been taken")
                end)

              if is_duplicate do
                Logger.warning("Duplicate custom_id attempted",
                  custom_id: full_data.custom_id,
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
    end
  end

  @impl true
  def handle_cast(:finish_building, state) do
    new_state = finish_building(state)
    {:noreply, new_state}
  end

  ## Private Functions

  defp should_mark_ready?(state) do
    state.request_count >= @max_requests or
      DateTime.diff(DateTime.utc_now(), state.started_at, :hour) >= @max_age_hours
  end

  defp finish_building(state) do
    Registry.unregister(Batcher.BatchRegistry, {state.url, state.model})

    batch = Batcher.Batching.get_batch_by_id!(state.batch_id)

    Batcher.Batching.start_batch_upload!(batch)

    Logger.info(
      "Batch #{state.batch_id} marked ready for upload: total_requests=#{state.request_count} total_size=#{Format.bytes(state.total_size_bytes)}"
    )

    %{state | status: :ready_for_upload}
  end

  defp schedule_expiry do
    time_in_millis = @max_age_hours * 60 * 60 * 1000
    Process.send_after(self(), :finish_building, time_in_millis)
  end

  defp get_batch(url, model) do
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
end
