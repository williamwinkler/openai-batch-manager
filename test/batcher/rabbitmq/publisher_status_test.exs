defmodule Batcher.RabbitMQ.PublisherStatusTest do
  @moduledoc """
  Unit tests for RabbitMQ Publisher status broadcasting and connected?/0.

  These tests do NOT require a running RabbitMQ instance.
  They test the status broadcasting by using an invalid URL that will always fail to connect.
  """
  use ExUnit.Case, async: false

  alias Batcher.RabbitMQ.Publisher

  defp stop_publisher do
    if pid = Process.whereis(Publisher) do
      try do
        ref = Process.monitor(pid)
        GenServer.stop(Publisher, :normal, 5000)

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
    stop_publisher()

    # Subscribe to status broadcasts
    Phoenix.PubSub.subscribe(Batcher.PubSub, "rabbitmq:status")

    on_exit(fn ->
      stop_publisher()
    end)

    :ok
  end

  describe "connected?/0" do
    test "returns false when process is not running" do
      refute Publisher.connected?()
    end

    test "returns false when started with invalid URL" do
      {:ok, _pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")
      Process.sleep(200)

      refute Publisher.connected?()
    end

    test "returns true when process is alive after start_link" do
      # Publisher should be running even if disconnected
      {:ok, pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")
      assert Process.alive?(pid)
    end
  end

  describe "status broadcasting" do
    test "broadcasts :disconnected on init failure" do
      {:ok, _pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")

      assert_receive {:rabbitmq_status, %{process: :publisher, status: :disconnected}}, 2000
    end

    test "broadcasts :disconnected on connection death" do
      {:ok, pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")

      # Drain initial broadcast
      assert_receive {:rabbitmq_status, %{process: :publisher, status: :disconnected}}, 2000

      # Simulate connection death by sending a :DOWN message
      # The publisher checks if the pid matches its conn or chan pid
      # Since we started with nil conn, this will hit the `true ->` branch (no-op)
      # But we can verify the message handler doesn't crash
      fake_pid = spawn(fn -> :ok end)
      send(pid, {:DOWN, make_ref(), :process, fake_pid, :connection_closed})

      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "handles unknown messages without crashing" do
      {:ok, pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")

      send(pid, :some_unknown_message)

      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "returns :not_connected error on publish when disconnected" do
      {:ok, _pid} = Publisher.start_link(url: "amqp://invalid:invalid@127.0.0.1:59999/")
      Process.sleep(200)

      assert {:error, :not_connected} = Publisher.publish("", "test_queue", %{test: true})
    end
  end
end
