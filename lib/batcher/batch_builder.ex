defmodule Batcher.BatchBuilder do
  @moduledoc """
  GenServer that aggregates prompts into batches.

  One BatchBuilder runs per {endpoint, model} combination. When the batch reaches
  capacity (50k prompts) or time limit (1 hour), it marks the batch ready for upload
  and shuts down. New requests will create a new BatchBuilder for that combination.

  ## Configuration

  See config.exs for:
  - max_prompts: Maximum prompts per batch (default: 50,000)
  - max_age_hours: Maximum age before marking ready (default: 1)
  - check_interval_minutes: How often to check if ready (default: 5)

  ## Registry

  BatchBuilders are registered in `Batcher.BatchRegistry` with key `{endpoint, model}`.
  """
  use GenServer
  require Logger

  alias Batcher.Batching.{BatchLimits, BatchQueries}
  alias Batcher.Utils.Format

  @max_prompts Application.compile_env(
                 :batcher,
                 [__MODULE__, :max_prompts],
                 BatchLimits.max_prompts_per_batch()
               )
  @max_age_hours Application.compile_env(:batcher, [__MODULE__, :max_age_hours], 1)
  @check_interval_ms Application.compile_env(
                       :batcher,
                       [__MODULE__, :check_interval_minutes],
                       5
                     ) * 60_000

  ## Client API

  @doc """
  Starts a BatchBuilder for the given endpoint and model combination.

  Options:
  - `test_pid` - Optional PID of the test process for sandbox allowance
  """
  def start_link({endpoint, model}) do
    GenServer.start_link(__MODULE__, {endpoint, model}, name: via_tuple(endpoint, model))
  end

  def start_link({endpoint, model, opts}) when is_list(opts) do
    GenServer.start_link(__MODULE__, {endpoint, model, opts}, name: via_tuple(endpoint, model))
  end

  @doc """
  Add a prompt to the batch for this endpoint/model combination.

  Returns:
  - `{:ok, prompt}` - Prompt successfully added
  - `{:error, :batch_full}` - Batch is full, retry will create new batch
  - `{:error, reason}` - Failed to create prompt
  """
  def add_prompt(endpoint, model, prompt_data) do
    case Registry.lookup(Batcher.BatchRegistry, {endpoint, model}) do
      [{pid, _}] ->
        GenServer.call(pid, {:add_prompt, prompt_data}, 30_000)

      [] ->
        # Start new BatchBuilder
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Batcher.BatchSupervisor,
            {__MODULE__, {endpoint, model}}
          )

        GenServer.call(pid, {:add_prompt, prompt_data}, 30_000)
    end
  end

  @doc """
  Get current state of a BatchBuilder (for monitoring/debugging).
  """
  def get_state(endpoint, model) do
    case Registry.lookup(Batcher.BatchRegistry, {endpoint, model}) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> {:error, :not_found}
    end
  end

  ## Server Callbacks

  @impl true
  def init({endpoint, model}) do
    init({endpoint, model, []})
  end

  def init({endpoint, model, opts}) do
    # Allow sandbox access for testing
    if test_pid = Keyword.get(opts, :test_pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Batcher.Repo, test_pid, self())
    end

    # Try to find an existing draft batch for this model/endpoint combination
    # If none exists, create a new one
    batch =
      case Batcher.Batching.find_draft_batch(model, endpoint) do
        {:ok, existing_batch} ->
          Logger.info(
            "BatchBuilder reusing existing draft batch: endpoint=#{endpoint} model=#{model} batch_id=#{existing_batch.id}"
          )

          existing_batch

        {:error, _} ->
          # No draft batch found, create a new one
          {:ok, new_batch} = Batcher.Batching.create_batch(model, endpoint)

          Logger.info(
            "BatchBuilder created new batch: endpoint=#{endpoint} model=#{model} batch_id=#{new_batch.id}"
          )

          new_batch
      end

    # Count existing prompts and sum their sizes to maintain accurate state
    prompt_count = BatchQueries.count_prompts_in_batch(batch.id)
    total_size_bytes = BatchQueries.sum_prompt_sizes_in_batch(batch.id)

    Logger.info(
      "BatchBuilder initialized: batch_id=#{batch.id} existing_prompts=#{prompt_count} total_size=#{Format.bytes(total_size_bytes)}"
    )

    # Schedule periodic check
    schedule_check()

    {:ok,
     %{
       batch_id: batch.id,
       endpoint: endpoint,
       model: model,
       prompt_count: prompt_count,
       total_size_bytes: total_size_bytes,
       started_at: DateTime.utc_now(),
       status: :collecting
     }}
  end

  @impl true
  def handle_call({:add_prompt, prompt_data}, _from, state) do
    cond do
      state.status != :collecting ->
        {:reply, {:error, :batch_full}, state}

      state.prompt_count >= @max_prompts ->
        mark_ready_and_close(state)
        {:reply, {:error, :batch_full}, state}

      true ->
        # Compute the size of this prompt to check if it fits
        # (The Ash change will compute it again, but we need it now for the check)
        prompt_size = BatchQueries.compute_payload_size(prompt_data.request_payload)
        new_total_size = state.total_size_bytes + prompt_size

        # Check if adding this prompt would exceed 200 MB limit
        if new_total_size > BatchLimits.max_batch_size_bytes() do
          Logger.info(
            "Batch #{state.batch_id} size limit reached. Current: #{Format.bytes(state.total_size_bytes)}, prompt: #{Format.bytes(prompt_size)}, would be: #{Format.bytes(new_total_size)}"
          )

          mark_ready_and_close(state)
          {:reply, {:error, :batch_full}, state}
        else
          # Create Prompt record via internal action
          full_data = Map.put(prompt_data, :batch_id, state.batch_id)

          Logger.debug(
            "Creating prompt via Ash: batch_id=#{full_data.batch_id} custom_id=#{full_data.custom_id} delivery_type=#{full_data.delivery_type} webhook_url=#{inspect(full_data.webhook_url)} rabbitmq_queue=#{inspect(full_data.rabbitmq_queue)}"
          )

          case Batcher.Batching.create_prompt(full_data) do
            {:ok, prompt} ->
              new_state = %{
                state
                | prompt_count: state.prompt_count + 1,
                  total_size_bytes: state.total_size_bytes + prompt.request_payload_size
              }

              Logger.debug(
                "[Batch #{state.batch_id}] Prompt created successfully. Total prompts: #{new_state.prompt_count}, total size: #{Format.bytes(new_state.total_size_bytes)}"
              )

              # Check if should mark ready (don't block the caller)
              if should_mark_ready?(new_state) do
                spawn(fn -> mark_ready_and_close(new_state) end)
              end

              {:reply, {:ok, prompt}, new_state}

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
                  "Failed to create prompt in database: #{inspect(error, pretty: true, limit: :infinity)}"
                )

                {:reply, {:error, error}, state}
              end

            {:error, error} ->
              Logger.error(
                "Failed to create prompt in database: #{inspect(error, pretty: true, limit: :infinity)}"
              )

              {:reply, {:error, error}, state}
          end
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:check_if_ready, state) do
    if should_mark_ready?(state) do
      mark_ready_and_close(state)
      {:noreply, state}
    else
      schedule_check()
      {:noreply, state}
    end
  end

  ## Private Functions

  defp should_mark_ready?(state) do
    state.prompt_count >= @max_prompts or
      DateTime.diff(DateTime.utc_now(), state.started_at, :hour) >= @max_age_hours
  end

  defp mark_ready_and_close(state) do
    # Call batch :mark_ready action
    {:ok, _batch} = Batcher.Batching.batch_mark_ready(state.batch_id)
    Logger.info("Batch #{state.batch_id} marked ready for upload")

    # Unregister from registry (new requests will create new BatchBuilder)
    Registry.unregister(Batcher.BatchRegistry, {state.endpoint, state.model})

    # Update status to prevent new prompts
    %{state | status: :ready_for_upload}
  end

  defp schedule_check do
    Process.send_after(self(), :check_if_ready, @check_interval_ms)
  end

  defp via_tuple(endpoint, model) do
    {:via, Registry, {Batcher.BatchRegistry, {endpoint, model}}}
  end
end
