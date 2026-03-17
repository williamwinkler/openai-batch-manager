defmodule Batcher.System.DeliveryQueueWatchdogTest do
  use ExUnit.Case, async: true

  alias Batcher.System.DeliveryQueueWatchdog

  @opts [
    min_available_jobs: 100,
    stale_after_seconds: 300,
    restart_cooldown_seconds: 300,
    delivery_limit: 8
  ]

  @now ~U[2026-03-16 12:00:00Z]
  @stale_at DateTime.add(@now, -301, :second)
  @fresh_at DateTime.add(@now, -60, :second)

  describe "decide_action/5" do
    test "starts the queue when stale backlog exists and the queue is not running" do
      metrics = %{available_count: 1_000, oldest_available_at: @stale_at}

      assert {:start, 8} =
               DeliveryQueueWatchdog.decide_action(nil, metrics, @now, nil, @opts)
    end

    test "resumes the queue when stale backlog exists and the queue is paused" do
      metrics = %{available_count: 1_000, oldest_available_at: @stale_at}
      queue_state = %{limit: 8, paused: true, running: []}

      assert :resume =
               DeliveryQueueWatchdog.decide_action(queue_state, metrics, @now, nil, @opts)
    end

    test "restarts the queue when stale backlog exists and no jobs are running" do
      metrics = %{available_count: 1_000, oldest_available_at: @stale_at}
      queue_state = %{limit: 8, paused: false, running: []}

      assert {:restart, 8} =
               DeliveryQueueWatchdog.decide_action(queue_state, metrics, @now, nil, @opts)
    end

    test "does nothing while the queue is actively running jobs" do
      metrics = %{available_count: 1_000, oldest_available_at: @stale_at}
      queue_state = %{limit: 8, paused: false, running: [123, 456]}

      assert :noop =
               DeliveryQueueWatchdog.decide_action(queue_state, metrics, @now, nil, @opts)
    end

    test "does nothing for fresh backlog" do
      metrics = %{available_count: 1_000, oldest_available_at: @fresh_at}
      queue_state = %{limit: 8, paused: false, running: []}

      assert :noop =
               DeliveryQueueWatchdog.decide_action(queue_state, metrics, @now, nil, @opts)
    end

    test "does nothing for small backlog" do
      metrics = %{available_count: 10, oldest_available_at: @stale_at}
      queue_state = %{limit: 8, paused: false, running: []}

      assert :noop =
               DeliveryQueueWatchdog.decide_action(queue_state, metrics, @now, nil, @opts)
    end

    test "respects remediation cooldown" do
      metrics = %{available_count: 1_000, oldest_available_at: @stale_at}
      queue_state = %{limit: 8, paused: false, running: []}
      last_remediation_at = DateTime.add(@now, -120, :second)

      assert :noop =
               DeliveryQueueWatchdog.decide_action(
                 queue_state,
                 metrics,
                 @now,
                 last_remediation_at,
                 @opts
               )
    end
  end
end
