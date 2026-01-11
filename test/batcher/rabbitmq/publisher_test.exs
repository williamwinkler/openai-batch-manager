defmodule Batcher.RabbitMQ.PublisherTest do
  @moduledoc """
  Integration tests for RabbitMQ Publisher.

  These tests require a running RabbitMQ instance.
  Run with: mix test --include rabbitmq
  Skip in CI: mix test --exclude rabbitmq
  """
  use ExUnit.Case, async: false
  use AMQP

  alias Batcher.RabbitMQ.Publisher

  @moduletag :rabbitmq

  # Helper to stop the publisher and wait for it to fully terminate
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

    # Extra wait to ensure all async operations are done
    Process.sleep(100)
  end

  setup do
    # Stop any existing publisher from previous tests
    stop_publisher()

    # Check if RabbitMQ is available
    rabbitmq_url =
      case System.get_env("RABBITMQ_URL") do
        nil -> "amqp://guest:guest@localhost:5672"
        "" -> "amqp://guest:guest@localhost:5672"
        url -> url
      end

    case Connection.open(rabbitmq_url) do
      {:ok, conn} ->
        {:ok, chan} = Channel.open(conn)
        test_queue = "test_publisher_#{System.unique_integer([:positive])}"
        test_exchange = "test_exchange_#{System.unique_integer([:positive])}"

        # Declare queue and exchange for tests
        {:ok, _} = Queue.declare(chan, test_queue, durable: true)
        :ok = Exchange.declare(chan, test_exchange, :direct, durable: true)
        :ok = Queue.bind(chan, test_queue, test_exchange, routing_key: "test.key")

        on_exit(fn ->
          try do
            Queue.delete(chan, test_queue)
            Exchange.delete(chan, test_exchange)
            Channel.close(chan)
            Connection.close(conn)
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok,
         conn: conn,
         chan: chan,
         queue: test_queue,
         exchange: test_exchange,
         rabbitmq_url: rabbitmq_url,
         stop_publisher: &stop_publisher/0,
         rabbitmq_available: true}

      {:error, _reason} ->
        {:ok, rabbitmq_available: false, rabbitmq_url: rabbitmq_url}
    end
  end

  # Helper to skip test if RabbitMQ is not available
  defp require_rabbitmq(context) do
    if context[:rabbitmq_available] != true do
      flunk(
        "RabbitMQ is not available. Make sure RabbitMQ is running. These tests are skipped by default. Run with: mix test --include rabbitmq"
      )
    end
  end

  describe "publishing" do
    test "publishes message to existing queue", context do
      require_rabbitmq(context)
      %{queue: queue, rabbitmq_url: rabbitmq_url, chan: chan} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      payload = %{message: "test", id: 123}

      # Publish to default exchange (empty string) with queue name as routing key
      assert :ok = Publisher.publish("", queue, payload)

      # Verify message was delivered
      case Basic.get(chan, queue) do
        {:ok, body, _meta} ->
          decoded = JSON.decode!(body)
          assert decoded["message"] == "test"
          assert decoded["id"] == 123

        {:empty, _meta} ->
          flunk("Expected message in queue but queue was empty")
      end
    end

    test "publishes message to exchange with routing key", context do
      require_rabbitmq(context)
      %{exchange: exchange, rabbitmq_url: rabbitmq_url, chan: chan, queue: queue} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      payload = %{message: "test exchange", id: 456}

      # Publish to named exchange
      assert :ok = Publisher.publish(exchange, "test.key", payload)

      # Verify message was delivered to bound queue
      case Basic.get(chan, queue) do
        {:ok, body, _meta} ->
          decoded = JSON.decode!(body)
          assert decoded["message"] == "test exchange"
          assert decoded["id"] == 456

        {:empty, _meta} ->
          flunk("Expected message in queue but queue was empty")
      end
    end

    test "returns error for non-existent queue", context do
      require_rabbitmq(context)
      %{rabbitmq_url: rabbitmq_url} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      non_existent_queue = "non_existent_queue_#{System.unique_integer([:positive])}"
      payload = %{message: "test"}

      # Should return error immediately
      assert {:error, :queue_not_found} = Publisher.publish("", non_existent_queue, payload)
    end

    test "returns error for non-existent exchange", context do
      require_rabbitmq(context)
      %{rabbitmq_url: rabbitmq_url} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      non_existent_exchange = "non_existent_exchange_#{System.unique_integer([:positive])}"
      payload = %{message: "test"}

      # Should return error immediately
      assert {:error, :exchange_not_found} =
               Publisher.publish(non_existent_exchange, "routing.key", payload)
    end

    test "caches failed destination and returns immediately on retry", context do
      require_rabbitmq(context)
      %{rabbitmq_url: rabbitmq_url} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      non_existent_queue = "non_existent_queue_#{System.unique_integer([:positive])}"
      payload = %{message: "test"}

      # First attempt - should try to connect and fail
      assert {:error, :queue_not_found} = Publisher.publish("", non_existent_queue, payload)

      # Second attempt - should return immediately from cache
      start_time = System.monotonic_time(:millisecond)
      assert {:error, :queue_not_found} = Publisher.publish("", non_existent_queue, payload)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be very fast (cached), not making network call
      assert elapsed < 100, "Expected cached response to be fast, took #{elapsed}ms"
    end

    test "caches successful destination", context do
      require_rabbitmq(context)
      %{queue: queue, rabbitmq_url: rabbitmq_url, chan: chan} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      payload1 = %{message: "first"}
      payload2 = %{message: "second"}

      # First publish - validates destination
      assert :ok = Publisher.publish("", queue, payload1)

      # Second publish - should use cached validation
      start_time = System.monotonic_time(:millisecond)
      assert :ok = Publisher.publish("", queue, payload2)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be fast (cached validation)
      assert elapsed < 200

      # Verify both messages were delivered
      case Basic.get(chan, queue) do
        {:ok, body1, _meta} ->
          case Basic.get(chan, queue) do
            {:ok, body2, _meta} ->
              assert JSON.decode!(body1)["message"] == "first"
              assert JSON.decode!(body2)["message"] == "second"

            {:empty, _meta} ->
              flunk("Expected second message in queue but queue was empty")
          end

        {:empty, _meta} ->
          flunk("Expected first message in queue but queue was empty")
      end
    end
  end

  describe "connection handling" do
    test "reconnects if connection dies", context do
      require_rabbitmq(context)
      %{queue: queue, rabbitmq_url: rabbitmq_url, conn: conn} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      # Verify it's connected by publishing
      assert :ok = Publisher.publish("", queue, %{test: "before"})

      # Kill the connection
      Connection.close(conn)
      Process.sleep(300)

      # Next publish should reconnect and succeed
      assert :ok = Publisher.publish("", queue, %{test: "after"})
    end

    test "starts even if initial connection fails", context do
      require_rabbitmq(context)

      # Start publisher with invalid URL - should start but not connect
      {:ok, _pid} =
        Publisher.start_link(url: "amqp://invalid:invalid@nonexistent:5672/")

      Process.sleep(100)

      # Publisher should be running but not connected
      assert Process.alive?(Process.whereis(Publisher))

      # Publish should fail with not_connected
      assert {:error, :not_connected} =
               Publisher.publish("", "test_queue", %{message: "test"})
    end
  end

  describe "cache management" do
    test "clear_destination_cache allows retry after queue creation", context do
      require_rabbitmq(context)
      %{rabbitmq_url: rabbitmq_url, chan: chan} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      new_queue = "new_queue_#{System.unique_integer([:positive])}"
      payload = %{message: "test"}

      # First attempt - queue doesn't exist
      assert {:error, :queue_not_found} = Publisher.publish("", new_queue, payload)

      # Create the queue
      {:ok, _} = Queue.declare(chan, new_queue, durable: true)

      # Clear cache and retry
      Publisher.clear_destination_cache("", new_queue)
      assert :ok = Publisher.publish("", new_queue, payload)

      # Cleanup
      Queue.delete(chan, new_queue)
    end

    test "clear_all_cache clears all destinations", context do
      require_rabbitmq(context)
      %{rabbitmq_url: rabbitmq_url} = context

      # Start publisher
      {:ok, _pid} = Publisher.start_link(url: rabbitmq_url)
      Process.sleep(200)

      queue1 = "queue1_#{System.unique_integer([:positive])}"
      queue2 = "queue2_#{System.unique_integer([:positive])}"

      # Both should fail
      assert {:error, :queue_not_found} = Publisher.publish("", queue1, %{test: 1})
      assert {:error, :queue_not_found} = Publisher.publish("", queue2, %{test: 2})

      # Clear all cache
      Publisher.clear_all_cache()

      # Both should fail again (not cached)
      assert {:error, :queue_not_found} = Publisher.publish("", queue1, %{test: 1})
      assert {:error, :queue_not_found} = Publisher.publish("", queue2, %{test: 2})
    end
  end
end
