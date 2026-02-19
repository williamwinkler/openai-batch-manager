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

    Process.sleep(100)
  end

  setup do
    stop_consumer()

    # Start PubSub if not already running (it's started by the application in most cases)
    # Subscribe to status broadcasts
    Phoenix.PubSub.subscribe(Batcher.PubSub, "rabbitmq:status")

    on_exit(fn ->
      stop_consumer()
    end)

    :ok
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

      # Wait for a natural reconnect cycle (1s backoff + fast connection failure)
      # The reconnect will fail and schedule another attempt with doubled backoff
      Process.sleep(1500)

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

      Process.sleep(100)

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

      Process.sleep(100)

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

      Process.sleep(100)
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
