# Sends large requests to verify batch size rollover/upload behavior.
#
# Usage:
#   mix run priv/scripts/big_payloads.exs
#
defmodule BigPayloadScript do
  @api_url "http://localhost:4000/api/requests"
  @model "gpt-4o-mini"
  @url "/v1/responses"
  @count 360
  @payload_bytes 350_000
  @webhook_url "https://example.com/webhook"

  def run do
    IO.puts("Sending #{@count} large requests to #{@api_url}")
    IO.puts("  endpoint: #{@url}")
    IO.puts("  model: #{@model}")
    IO.puts("  input_bytes/request: #{@payload_bytes}")

    start_ms = System.monotonic_time(:millisecond)

    results =
      for i <- 1..@count do
        req = build_request(i)

        case Req.post(@api_url, json: req, headers: [{"content-type", "application/json"}]) do
          {:ok, %{status: status}} ->
            {:ok, status}

          {:error, reason} ->
            {:error, reason}
        end
      end

    duration_ms = System.monotonic_time(:millisecond) - start_ms

    accepted = Enum.count(results, &match?({:ok, 202}, &1))
    conflicts = Enum.count(results, &match?({:ok, 409}, &1))

    other_http =
      Enum.count(results, fn
        {:ok, status} when status not in [202, 409] -> true
        _ -> false
      end)

    transport = Enum.count(results, &match?({:error, _}, &1))

    IO.puts("Done in #{duration_ms}ms")
    IO.puts("  accepted: #{accepted}")
    IO.puts("  conflicts: #{conflicts}")
    IO.puts("  other_http: #{other_http}")
    IO.puts("  transport_errors: #{transport}")
  end

  defp build_request(i) do
    %{
      "custom_id" => "big_#{i}_#{System.unique_integer([:positive])}",
      "url" => @url,
      "method" => "POST",
      "body" => %{
        "model" => @model,
        "input" => String.duplicate("x", @payload_bytes)
      },
      "delivery_config" => %{
        "type" => "webhook",
        "webhook_url" => @webhook_url
      }
    }
  end
end

BigPayloadScript.run()
