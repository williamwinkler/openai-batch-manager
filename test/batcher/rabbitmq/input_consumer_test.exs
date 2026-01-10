defmodule Batcher.RabbitMQ.InputConsumerTest do
  @moduledoc """
  Integration tests for RabbitMQ InputConsumer.

  These tests require a running RabbitMQ instance.
  Run with: mix test --include rabbitmq
  Skip in CI: mix test --exclude rabbitmq
  """
  use Batcher.DataCase, async: false
  use AMQP

  alias Batcher.RabbitMQ.InputConsumer

  @moduletag :rabbitmq

  # Helper to stop the consumer and wait for it to fully terminate
  defp stop_consumer do
    if pid = Process.whereis(InputConsumer) do
      try do
        ref = Process.monitor(pid)
        GenServer.stop(InputConsumer, :normal, 5000)

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
    # Stop any existing consumer from previous tests
    stop_consumer()

    # Enable shared sandbox mode so the InputConsumer GenServer can access the database
    Ecto.Adapters.SQL.Sandbox.mode(Batcher.Repo, {:shared, self()})

    # Generate a unique model name per test to ensure complete isolation
    # This avoids any interference from existing batches or BatchBuilder processes
    test_model = "not-a-real-model-#{System.unique_integer([:positive])}"

    # Check if RabbitMQ is available
    # Use default URL if env var is not set or empty
    rabbitmq_url =
      case System.get_env("RABBITMQ_URL") do
        nil -> "amqp://guest:guest@localhost:5672"
        "" -> "amqp://guest:guest@localhost:5672"
        url -> url
      end

    case Connection.open(rabbitmq_url) do
      {:ok, conn} ->
        {:ok, chan} = Channel.open(conn)
        test_queue = "test_openai_batch_manager_input_#{System.unique_integer([:positive])}"

        # Declare queue before tests (consumer expects it to exist)
        {:ok, _} = Queue.declare(chan, test_queue, durable: true)

        # Store RabbitMQ resources for cleanup
        # Note: We clean up the consumer in the test body, not in on_exit
        on_exit(fn ->
          try do
            Queue.delete(chan, test_queue)
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
         model: test_model,
         rabbitmq_url: rabbitmq_url,
         stop_consumer: &stop_consumer/0,
         rabbitmq_available: true}

      {:error, _reason} ->
        # Return context indicating RabbitMQ is not available
        # Tests will check this and fail with a clear message if needed
        {:ok, rabbitmq_available: false, model: test_model, rabbitmq_url: rabbitmq_url}
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

  # Helper to retry a function until it returns a truthy value
  defp retry_until(fun, max_attempts, delay_ms) do
    case fun.() do
      nil ->
        if max_attempts > 1 do
          Process.sleep(delay_ms)
          retry_until(fun, max_attempts - 1, delay_ms)
        else
          nil
        end

      result ->
        result
    end
  end

  describe "message processing" do
    test "processes valid message and creates request", context do
      require_rabbitmq(context)
      %{chan: chan, queue: queue, model: model, rabbitmq_url: rabbitmq_url} = context
      alias Batcher.Batching

      # Start consumer (queue must exist)
      {:ok, _pid} =
        InputConsumer.start_link(
          url: rabbitmq_url,
          queue: queue
        )

      # Give consumer time to connect
      Process.sleep(200)

      custom_id = "rabbitmq-test-#{System.unique_integer([:positive])}"

      message =
        JSON.encode!(%{
          "custom_id" => custom_id,
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => model,
            "input" => "Test input from RabbitMQ"
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      :ok = Basic.publish(chan, "", queue, message)

      # Wait for processing
      Process.sleep(1000)

      # Stop consumer BEFORE test ends (while sandbox is still active)
      stop_consumer()

      # Verify request was created by finding it in a batch
      # Retry finding the batch since BatchBuilder creates it asynchronously
      # Increase retries and delay to give more time for batch creation
      batch =
        retry_until(
          fn ->
            {:ok, batches} = Batching.list_batches()
            # Don't assert here - just return nil if no batches found, let retry continue
            if length(batches) >= 1 do
              Enum.find(batches, fn b -> b.url == "/v1/responses" and b.model == model end)
            else
              nil
            end
          end,
          20,
          200
        )

      assert batch != nil, "Expected to find a batch for /v1/responses and #{model}"

      # Verify the request exists in the batch
      {:ok, requests} = Batching.list_requests_in_batch(batch.id)
      request = Enum.find(requests, fn r -> r.custom_id == custom_id end)
      assert request != nil
      assert request.url == "/v1/responses"
      assert request.model == model
    end

    test "rejects invalid JSON message", context do
      require_rabbitmq(context)
      %{chan: chan, queue: queue, rabbitmq_url: rabbitmq_url} = context
      alias Batcher.Batching

      # Get initial batch count
      {:ok, batches_before} = Batching.list_batches()
      initial_batch_count = length(batches_before)

      # Start consumer (queue must exist)
      {:ok, _pid} =
        InputConsumer.start_link(
          url: rabbitmq_url,
          queue: queue
        )

      # Give consumer time to connect
      Process.sleep(200)

      invalid_message = "{invalid json}"

      :ok = Basic.publish(chan, "", queue, invalid_message)

      # Wait for processing
      Process.sleep(500)

      # Stop consumer BEFORE test ends (while sandbox is still active)
      stop_consumer()

      # Message should be rejected (not requeued) - no new batches or requests should be created
      {:ok, batches_after} = Batching.list_batches()
      assert length(batches_after) == initial_batch_count
    end

    test "handles duplicate custom_id", context do
      require_rabbitmq(context)
      %{chan: chan, queue: queue, model: model, rabbitmq_url: rabbitmq_url} = context
      alias Batcher.Batching

      # Start consumer (queue must exist)
      {:ok, _pid} =
        InputConsumer.start_link(
          url: rabbitmq_url,
          queue: queue
        )

      # Give consumer time to connect
      Process.sleep(200)

      custom_id = "duplicate-test-#{System.unique_integer([:positive])}"

      message =
        JSON.encode!(%{
          "custom_id" => custom_id,
          "url" => "/v1/responses",
          "method" => "POST",
          "body" => %{
            "model" => model,
            "input" => "Test"
          },
          "delivery" => %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Publish first message
      :ok = Basic.publish(chan, "", queue, message)
      Process.sleep(1000)

      # Publish duplicate
      :ok = Basic.publish(chan, "", queue, message)
      Process.sleep(1000)

      # Stop consumer BEFORE test ends (while sandbox is still active)
      stop_consumer()

      # Both should be acked (first succeeds, second is duplicate but processed)
      # Verify only one request was created (duplicate is acked but not created)
      # Find the request by searching all batches since BatchBuilder creates batches asynchronously
      request =
        retry_until(
          fn ->
            {:ok, batches} = Batching.list_batches()

            Enum.reduce_while(batches, nil, fn batch, _acc ->
              {:ok, requests} = Batching.list_requests_in_batch(batch.id)

              case Enum.find(requests, fn r -> r.custom_id == custom_id end) do
                nil -> {:cont, nil}
                found_request -> {:halt, found_request}
              end
            end)
          end,
          20,
          200
        )

      assert request != nil, "Expected to find a request with custom_id #{custom_id}"

      # Verify it's in the correct batch
      batch = Batching.get_batch_by_id!(request.batch_id)
      assert batch.url == "/v1/responses"
      assert batch.model == model

      # Verify only one request exists with this custom_id (duplicate was acked but not created)
      {:ok, all_requests} = Batching.list_requests_in_batch(batch.id)
      matching_requests = Enum.filter(all_requests, fn r -> r.custom_id == custom_id end)

      assert length(matching_requests) == 1,
             "Expected exactly one request, found #{length(matching_requests)}"
    end
  end

  describe "connection handling" do
    test "fails to start when connection fails on startup" do
      # The consumer raises when it can't connect (fail-fast behavior)
      # This ensures the application doesn't start with a broken RabbitMQ connection
      # When init raises, GenServer.start_link causes the calling process to exit
      # We use spawn_monitor to catch the process exit
      {pid, ref} =
        spawn_monitor(fn ->
          InputConsumer.start_link(
            url: "amqp://invalid:invalid@nonexistent:5672/",
            queue: "test_queue"
          )
        end)

      # Wait for the DOWN message
      receive do
        {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: message}, _stacktrace}} ->
          assert message =~ "RabbitMQ connection failed"

        {:DOWN, ^ref, :process, ^pid, reason} ->
          flunk("Expected RuntimeError, got: #{inspect(reason)}")
      after
        5000 ->
          flunk("Expected process to exit, but it didn't")
      end
    end
  end
end
