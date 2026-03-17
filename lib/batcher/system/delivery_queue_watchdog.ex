defmodule Batcher.System.DeliveryQueueWatchdog do
  @moduledoc """
  Watches the local Oban `delivery` queue and restarts it when a stale backlog
  accumulates without any running jobs.

  This is intended to help the single-node sleep/wake case where delivery jobs
  remain `available` in Oban but the local queue stops draining them.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Batcher.Repo
  alias Oban.Job

  @queue :delivery
  @worker "Batcher.Batching.Request.AshOban.Worker.Deliver"

  @default_check_interval_ms :timer.minutes(1)
  @default_stale_after_seconds 5 * 60
  @default_restart_cooldown_seconds 5 * 60
  @default_restart_delay_ms 1_000
  @default_min_available_jobs 100
  @default_delivery_limit 8

  @type metrics :: %{
          available_count: non_neg_integer(),
          oldest_available_at: DateTime.t() | nil
        }

  @type queue_state :: %{
          optional(:limit) => pos_integer(),
          optional(:paused) => boolean(),
          optional(:running) => [term()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec decide_action(nil | queue_state(), metrics(), DateTime.t(), DateTime.t() | nil, keyword()) ::
          :noop | :resume | {:start, pos_integer()} | {:restart, pos_integer()}
  def decide_action(queue_state, metrics, now, last_remediation_at, opts \\ []) do
    opts = Keyword.merge(defaults(), opts)

    cond do
      metrics.available_count < opts[:min_available_jobs] ->
        :noop

      is_nil(metrics.oldest_available_at) ->
        :noop

      DateTime.diff(now, metrics.oldest_available_at, :second) < opts[:stale_after_seconds] ->
        :noop

      cooldown_active?(last_remediation_at, now, opts[:restart_cooldown_seconds]) ->
        :noop

      is_nil(queue_state) ->
        {:start, opts[:delivery_limit]}

      Map.get(queue_state, :paused, false) ->
        :resume

      Enum.empty?(Map.get(queue_state, :running, [])) ->
        {:restart, queue_limit(queue_state, opts[:delivery_limit])}

      true ->
        :noop
    end
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> Keyword.merge(defaults())
      |> Enum.into(%{})
      |> Map.put(:last_remediation_at, nil)

    schedule_check(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = maybe_remediate(state)
    schedule_check(state.check_interval_ms)
    {:noreply, state}
  end

  def handle_info({:start_queue, limit}, state) do
    now = DateTime.utc_now()

    case Oban.start_queue(queue: @queue, limit: limit, local_only: true) do
      :ok ->
        Logger.warning("Delivery queue watchdog started local delivery queue with limit=#{limit}")

      {:error, error} ->
        Logger.warning(
          "Delivery queue watchdog failed to start local delivery queue: #{inspect(error)}"
        )
    end

    {:noreply, %{state | last_remediation_at: now}}
  end

  defp maybe_remediate(state) do
    now = DateTime.utc_now()
    metrics = load_metrics()
    queue_state = Oban.check_queue(queue: @queue)

    case decide_action(queue_state, metrics, now, state.last_remediation_at, Map.to_list(state)) do
      :noop ->
        state

      :resume ->
        log_action("resuming", metrics, queue_state)

        case Oban.resume_queue(queue: @queue, local_only: true) do
          :ok ->
            %{state | last_remediation_at: now}

          {:error, error} ->
            Logger.warning(
              "Delivery queue watchdog failed to resume local delivery queue: #{inspect(error)}"
            )

            state
        end

      {:start, limit} ->
        log_action("starting", metrics, queue_state)
        send(self(), {:start_queue, limit})
        %{state | last_remediation_at: now}

      {:restart, limit} ->
        log_action("restarting", metrics, queue_state)

        case Oban.stop_queue(queue: @queue, local_only: true) do
          :ok ->
            Process.send_after(self(), {:start_queue, limit}, state.restart_delay_ms)
            %{state | last_remediation_at: now}

          {:error, error} ->
            Logger.warning(
              "Delivery queue watchdog failed to stop local delivery queue: #{inspect(error)}"
            )

            state
        end
    end
  end

  defp load_metrics do
    {available_count, oldest_available_at} =
      Job
      |> where([job], job.queue == ^to_string(@queue))
      |> where([job], job.worker == ^@worker)
      |> where([job], job.state == "available")
      |> select([job], {count(job.id), min(job.inserted_at)})
      |> Repo.one()

    %{
      available_count: available_count || 0,
      oldest_available_at: oldest_available_at
    }
  end

  defp log_action(action, metrics, queue_state) do
    oldest_age_seconds =
      case metrics.oldest_available_at do
        nil -> 0
        oldest -> DateTime.diff(DateTime.utc_now(), oldest, :second)
      end

    Logger.warning(
      "Delivery queue watchdog #{action} local delivery queue: available_jobs=#{metrics.available_count}, " <>
        "oldest_available_age_seconds=#{oldest_age_seconds}, queue_state=#{inspect(queue_state)}"
    )
  end

  defp queue_limit(queue_state, fallback) do
    queue_state
    |> Map.get(:limit, fallback)
    |> case do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> fallback
    end
  end

  defp cooldown_active?(nil, _now, _seconds), do: false

  defp cooldown_active?(last_remediation_at, now, cooldown_seconds) do
    DateTime.diff(now, last_remediation_at, :second) < cooldown_seconds
  end

  defp schedule_check(delay_ms) do
    Process.send_after(self(), :check, delay_ms)
  end

  defp defaults do
    [
      check_interval_ms: @default_check_interval_ms,
      stale_after_seconds: @default_stale_after_seconds,
      restart_cooldown_seconds: @default_restart_cooldown_seconds,
      restart_delay_ms: @default_restart_delay_ms,
      min_available_jobs: @default_min_available_jobs,
      delivery_limit: configured_delivery_limit()
    ]
  end

  defp configured_delivery_limit do
    :batcher
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> Keyword.get(@queue, @default_delivery_limit)
    |> case do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_delivery_limit
    end
  end
end
