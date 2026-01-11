# priv/scripts/load_test.exs
# Efficient load test script to send 50,001 requests via HTTP and RabbitMQ
#
# Usage: mix run priv/scripts/load_test.exs
#
# This will create:
# - One batch with 50,000 requests (max batch size)
# - One batch with 1 request (overflow)

defmodule LoadTest do
  @http_url "http://localhost:4000/api/requests"
  @rabbitmq_url "amqp://guest:guest@localhost:5672"
  @input_queue "test-input-queue"

  # Configuration
  @total_requests 50_001
  @http_requests 0
  @rabbitmq_requests 50_001
  @http_concurrency 100

  def run do
    IO.puts("🚀 Load Test: Sending #{@total_requests} requests")
    IO.puts("   - HTTP: #{@http_requests} requests (#{@http_concurrency} concurrent)")
    IO.puts("   - RabbitMQ: #{@rabbitmq_requests} requests")
    IO.puts("")

    # Run HTTP and RabbitMQ in parallel
    http_task = Task.async(fn -> send_http_requests() end)
    rabbitmq_task = Task.async(fn -> send_rabbitmq_requests() end)

    # Wait for both to complete
    http_result = Task.await(http_task, :infinity)
    rabbitmq_result = Task.await(rabbitmq_task, :infinity)

    IO.puts("")
    IO.puts("✅ Load test complete!")
    IO.puts("   - HTTP: #{http_result.success}/#{http_result.total} successful (#{http_result.duration_ms}ms)")
    IO.puts("   - RabbitMQ: #{rabbitmq_result.success}/#{rabbitmq_result.total} published (#{rabbitmq_result.duration_ms}ms)")
  end

  defp send_http_requests do
    IO.puts("[HTTP] Starting #{@http_requests} requests...")
    start_time = System.monotonic_time(:millisecond)

    results =
      1..@http_requests
      |> Task.async_stream(
        fn i ->
          req = build_request("http_#{i}_#{random_id()}")

          case Req.post(@http_url, json: req, receive_timeout: 30_000) do
            {:ok, %{status: status}} when status in 200..299 -> :ok
            {:ok, %{status: status}} -> {:error, status}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: @http_concurrency,
        timeout: 60_000,
        ordered: false
      )
      |> Enum.reduce(%{success: 0, failed: 0}, fn
        {:ok, :ok}, acc -> %{acc | success: acc.success + 1}
        _, acc -> %{acc | failed: acc.failed + 1}
      end)

    duration_ms = System.monotonic_time(:millisecond) - start_time
    IO.puts("[HTTP] Done: #{results.success} success, #{results.failed} failed")

    %{success: results.success, total: @http_requests, duration_ms: duration_ms}
  end

  defp send_rabbitmq_requests do
    IO.puts("[RabbitMQ] Starting #{@rabbitmq_requests} requests...")
    start_time = System.monotonic_time(:millisecond)

    case AMQP.Connection.open(@rabbitmq_url) do
      {:ok, conn} ->
        {:ok, chan} = AMQP.Channel.open(conn)
        {:ok, _} = AMQP.Queue.declare(chan, @input_queue, durable: true)

        # Publish all messages (non-blocking)
        success_count =
          1..@rabbitmq_requests
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

        %{success: success_count, total: @rabbitmq_requests, duration_ms: duration_ms}

      {:error, reason} ->
        IO.puts("[RabbitMQ] Connection failed: #{inspect(reason)}")
        %{success: 0, total: @rabbitmq_requests, duration_ms: 0}
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
        "type" => "webhook",
        "webhook_url" => "https://webhook.site/737a3db4-1de7-429e-aae6-6239a3582fe9"
      }
    }
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end

# Run the load test
LoadTest.run()
