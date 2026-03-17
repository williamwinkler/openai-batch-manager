defmodule Batcher.RabbitMQ.ConsumerReconnectTest do
  @moduledoc """
  Unit tests for RabbitMQ Consumer reconnection and status broadcasting.

  These tests do NOT require a running RabbitMQ instance.
  They test the reconnection logic by using an invalid URL that will always fail to connect.
  """
  use ExUnit.Case, async: false

  alias Batcher.RabbitMQ.Consumer

  defmodule GateOn do
    def enabled?, do: true
  end

  defmodule ValidatorOk do
    def validate_json(_payload), do: {:ok, %{custom_id: "x"}}
  end

  defmodule HandlerOk do
    def handle(_validated), do: {:ok, %{id: 1}}
  end

  defp stop_consumer do
    if pid = Process.whereis(Consumer) do
      try do
        ref = Process.monitor(pid)
        GenServer.stop(Consumer, :normal, 5000)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5000 -> :ok
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    assert_eventually(fn -> Process.whereis(Consumer) == nil end, 500, 10)
  end

  setup do
    original_consumer_cfg = Application.get_env(:batcher, :rabbitmq_consumer, [])
    Application.put_env(:batcher, :rabbitmq_consumer, initial_backoff_ms: 25, max_backoff_ms: 100)

    stop_consumer()

    # Start PubSub if not already running (it's started by the application in most cases)
    # Subscribe to status broadcasts
    Phoenix.PubSub.subscribe(Batcher.PubSub, "rabbitmq:status")

    on_exit(fn ->
      Application.put_env(:batcher, :rabbitmq_consumer, original_consumer_cfg)
      stop_consumer()
    end)

    :ok
  end

  defp assert_eventually(fun, timeout_ms, interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met within timeout")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end

  describe "disconnected state and reconnection" do
    test "starts in disconnected state when connection fails" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      assert Process.alive?(pid)
      refute Consumer.connected?()

      # Should receive a :disconnected status broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000
    end

    test "connected?/0 returns false when process is not running" do
      refute Consumer.connected?()
    end

    test "survives multiple reconnect attempts without crashing" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      # Drain the initial disconnected broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 5000

      # With short test backoff configured, we should quickly observe backoff growth.
      assert_eventually(
        fn ->
          state = :sys.get_state(pid)
          state.backoff_ms > 25
        end,
        1_000,
        10
      )

      # Consumer should still be alive after failed reconnect attempts
      assert Process.alive?(pid)
      refute Consumer.connected?()
    end

    test "handles :DOWN message without crashing" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      # Drain initial disconnected broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000

      # Simulate a :DOWN message (as if connection process died)
      fake_pid = spawn(fn -> :ok end)
      send(pid, {:DOWN, make_ref(), :process, fake_pid, :connection_closed})
      assert_eventually(fn -> Process.alive?(pid) end, 300, 10)

      # Consumer should still be alive
      assert Process.alive?(pid)
    end

    test "handles :basic_cancel without crashing" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      # Drain initial disconnected broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000

      # Simulate broker cancellation
      send(pid, {:basic_cancel, %{consumer_tag: "fake_tag"}})
      assert_eventually(fn -> Process.alive?(pid) end, 300, 10)

      # Consumer should still be alive
      assert Process.alive?(pid)
    end

    test "handles unknown messages without crashing" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      send(pid, :some_unknown_message)
      assert_eventually(fn -> Process.alive?(pid) end, 300, 10)
      assert Process.alive?(pid)
    end
  end

  describe "status broadcasting" do
    test "broadcasts :disconnected on init failure" do
      {:ok, _pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000
    end

    test "broadcasts :disconnected on :basic_cancel" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      # Drain initial broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000

      # Simulate broker cancellation
      send(pid, {:basic_cancel, %{consumer_tag: "test_tag"}})

      # Should receive another disconnected broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000
    end

    test "broadcasts :disconnected on :DOWN" do
      {:ok, pid} =
        Consumer.start_link(
          url: "amqp://invalid:invalid@127.0.0.1:59999/",
          queue: "test_queue"
        )

      # Drain initial broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000

      # Simulate connection death
      fake_pid = spawn(fn -> :ok end)
      send(pid, {:DOWN, make_ref(), :process, fake_pid, :connection_closed})

      # Should receive another disconnected broadcast
      assert_receive {:rabbitmq_status, %{process: :consumer, status: :disconnected}}, 2000
    end
  end

  describe "maintenance gate behavior" do
    test "requeues intake messages while maintenance mode is enabled" do
      assert Consumer.decide_message_action("{}", ValidatorOk, HandlerOk, GateOn) == {:nack, true}
    end
  end
end
