# priv/scripts/load_test.exs
# Load test script to publish requests to RabbitMQ input queue
#
# Usage: mix run priv/scripts/load_test.exs
#
# Publishes requests that will be delivered to the "batch_results" RabbitMQ queue.

defmodule LoadTest do
  @rabbitmq_url "amqp://guest:guest@localhost:5672"
  @input_queue "test-input-queue"

  @total_requests 50_001

  def run do
    IO.puts("Load Test: Publishing #{@total_requests} requests to RabbitMQ")
    IO.puts("  Input queue: #{@input_queue}")
    IO.puts("  Delivery queue: batch_results")
    IO.puts("")

    result = send_rabbitmq_requests()

    IO.puts("")
    IO.puts("Load test complete!")
    IO.puts("  #{result.success}/#{result.total} published (#{result.duration_ms}ms)")
  end

  defp send_rabbitmq_requests do
    IO.puts("[RabbitMQ] Connecting...")
    start_time = System.monotonic_time(:millisecond)

    case AMQP.Connection.open(@rabbitmq_url) do
      {:ok, conn} ->
        {:ok, chan} = AMQP.Channel.open(conn)
        {:ok, _} = AMQP.Queue.declare(chan, @input_queue, durable: true)

        IO.puts("[RabbitMQ] Publishing #{@total_requests} requests...")

        success_count =
          1..@total_requests
          |> Enum.reduce(0, fn i, count ->
            req = build_request("rmq_#{i}_#{random_id()}")
            json = JSON.encode!(req)

            case AMQP.Basic.publish(chan, "", @input_queue, json, persistent: true) do
              :ok -> count + 1
              _ -> count
            end
          end)

        AMQP.Channel.close(chan)
        AMQP.Connection.close(conn)

        duration_ms = System.monotonic_time(:millisecond) - start_time
        IO.puts("[RabbitMQ] Done: #{success_count} published")

        %{success: success_count, total: @total_requests, duration_ms: duration_ms}

      {:error, reason} ->
        IO.puts("[RabbitMQ] Connection failed: #{inspect(reason)}")
        %{success: 0, total: @total_requests, duration_ms: 0}
    end
  end

  defp build_request(custom_id) do
    %{
      "custom_id" => custom_id,
      "url" => "/v1/responses",
      "method" => "POST",
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "Hi"
      },
      "delivery_config" => %{
        "type" => "rabbitmq",
        "rabbitmq_queue" => "batch_results"
      }
    }
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end

LoadTest.run()
