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

  @max_prompts Application.compile_env(:batcher, [__MODULE__, :max_prompts], 50_000)
  @max_age_hours Application.compile_env(:batcher, [__MODULE__, :max_age_hours], 1)
  @check_interval_ms Application.compile_env(
                       :batcher,
                       [__MODULE__, :check_interval_minutes],
                       5
                     ) * 60_000

  ## Client API

  @doc """
  Starts a BatchBuilder for the given endpoint and model combination.
  """
  def start_link({endpoint, model}) do
    GenServer.start_link(__MODULE__, {endpoint, model}, name: via_tuple(endpoint, model))
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
    # Create new Batch in database (provider defaults to :openai)
    {:ok, batch} = Batcher.Batching.create_batch(model, endpoint)

    Logger.info("BatchBuilder started: endpoint=#{endpoint} model=#{model} batch_id=#{batch.id}")

    # Schedule periodic check
    schedule_check()

    {:ok,
     %{
       batch_id: batch.id,
       endpoint: endpoint,
       model: model,
       prompt_count: 0,
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
        # Create Prompt record via internal action
        full_data = Map.put(prompt_data, :batch_id, state.batch_id)

        case Batcher.Batching.create_prompt_internal(full_data) do
          {:ok, prompt} ->
            new_state = %{state | prompt_count: state.prompt_count + 1}

            # Check if should mark ready (don't block the caller)
            if should_mark_ready?(new_state) do
              spawn(fn -> mark_ready_and_close(new_state) end)
            end

            {:reply, {:ok, prompt}, new_state}

          {:error, error} ->
            {:reply, {:error, error}, state}
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
    Logger.info(
      "Marking batch #{state.batch_id} ready for upload (#{state.prompt_count} prompts)"
    )

    # Call batch :mark_ready action
    {:ok, _batch} = Batcher.Batching.batch_mark_ready(state.batch_id)

    # TODO: Trigger Oban job to upload batch

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
