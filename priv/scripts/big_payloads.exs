# Sends large requests to verify batch size rollover/upload behavior.
#
# Usage:
#   mix run priv/scripts/big_payloads.exs
#
defmodule BigPayloadScript do
  @api_url "http://localhost:4001/api/requests"
  @model "gpt-4o-mini"
  @url "/v1/responses"
  @count 50_000
  @payload_bytes 16_384
  @webhook_url "https://example.com/webhook"
  @payload_scenarios [
    %{
      input: """
      Incident Report
      Service: batch-orchestrator
      Date: 2026-02-10
      Summary: Elevated queue latency observed between 14:05 and 14:37 UTC.
      Symptoms:
      - p95 enqueue-to-dispatch latency increased from 900ms to 12.4s
      - Duplicate webhook deliveries observed for 0.7% of completed items
      - Capacity controller oscillated between admit/reject every 20-30 seconds
      Findings:
      1) Upstream retries surged during a partial provider outage.
      2) The worker pool was saturated by long-running download jobs.
      3) Backoff policy used fixed intervals instead of jittered exponential backoff.
      Action items:
      - Introduce per-model fairness queue
      - Add jitter to retry policy
      - Separate dispatch and retrieval worker pools
      """
    },
    %{
      input: """
      Product Requirements Document
      Feature: Capacity-Aware Admission
      Goal:
      Admit requests into batches based on model-level token budgets while maximizing throughput.
      Constraints:
      - Requests must preserve FIFO fairness within each tenant.
      - Admission decisions must be deterministic and auditable.
      - State transitions must remain idempotent under retries.
      Non-goals:
      - Dynamic model selection at runtime
      - Automatic prompt rewriting
      Acceptance criteria:
      - 99% of waiting requests are admitted within 5 minutes under steady load.
      - Throughput degrades gracefully under provider rate limit reductions.
      - Operators can inspect waiting reason and last capacity check timestamp.
      """
    },
    %{
      input: """
      Customer Support Conversation
      Agent: Thanks for contacting support. Could you share your request id and approximate timestamp?
      Customer: Request id req_9fc21, around 08:13 UTC. The response came back empty.
      Agent: I can see the batch transitioned from validating to in_progress and then completed.
      Customer: Why did my payload fail validation if it completed?
      Agent: It completed at the batch level, but one request item was rejected due to malformed JSON.
      Customer: Can I retry just that one item?
      Agent: Yes. Resubmit the failed item with a new custom_id and we'll deduplicate safely.
      Customer: Great, can you include webhook retries if my endpoint is down?
      Agent: Absolutely. We'll retry with exponential backoff for up to 24 hours.
      """
    },
    %{
      input: """
      Security Triage Task
      Analyze this incident and return structured data matching the response schema.
      Evidence:
      - API token rotation failed for one tenant after a deployment.
      - 342 requests were rejected with invalid_signature during 18 minutes.
      - No unauthorized reads detected in audit logs.
      - Temporary mitigation was manual key re-issuance.
      - Follow-up work includes key lifecycle automation and deployment safeguards.
      """,
      text: %{
        "format" => %{
          "type" => "json_schema",
          "name" => "security_triage_result",
          "schema" => %{
            "type" => "object",
            "properties" => %{
              "incident_id" => %{"type" => "string"},
              "severity" => %{
                "type" => "string",
                "enum" => ["low", "medium", "high", "critical"]
              },
              "root_causes" => %{"type" => "array", "items" => %{"type" => "string"}},
              "customer_impact" => %{
                "type" => "object",
                "properties" => %{
                  "affected_users" => %{"type" => "integer"},
                  "data_exposure" => %{"type" => "boolean"},
                  "summary" => %{"type" => "string"}
                },
                "required" => ["affected_users", "data_exposure", "summary"],
                "additionalProperties" => false
              },
              "recommended_actions" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "owner" => %{"type" => "string"},
                    "action" => %{"type" => "string"},
                    "eta_hours" => %{"type" => "integer"}
                  },
                  "required" => ["owner", "action", "eta_hours"],
                  "additionalProperties" => false
                }
              }
            },
            "required" => [
              "incident_id",
              "severity",
              "root_causes",
              "customer_impact",
              "recommended_actions"
            ],
            "additionalProperties" => false
          }
        }
      }
    },
    %{
      input: """
      Scraped Web Page Extraction Task
      Source URL: https://store.example.com/products/ultralight-hiking-pack
      Raw scraped content:
      <html>
      <head><title>Ultralight Hiking Pack 38L - SummitTrail</title></head>
      <body>
      <h1>Ultralight Hiking Pack 38L</h1>
      <p class="subtitle">Built for multi-day treks and carry-on travel.</p>
      <div class="pricing">
        <span class="price">$149.00</span>
        <span class="sale">Now $119.00</span>
      </div>
      <ul class="specs">
        <li>Capacity: 38 liters</li>
        <li>Weight: 0.92 kg</li>
        <li>Material: Ripstop nylon, recycled 60%</li>
        <li>Frame: Removable aluminum stay</li>
      </ul>
      <div class="shipping">Ships in 2-3 business days from Denver, CO.</div>
      <div class="returns">30-day returns. Final sale colors excluded.</div>
      <div class="rating">4.7 out of 5 (1,284 reviews)</div>
      <div class="faq">
        <p>Q: Is it carry-on compatible?</p>
        <p>A: Yes, fits most domestic overhead bins when not overpacked.</p>
      </div>
      </body>
      </html>
      Extract structured product data using the provided response schema.
      """,
      text: %{
        "format" => %{
          "type" => "json_schema",
          "name" => "scraped_product_extraction",
          "schema" => %{
            "type" => "object",
            "properties" => %{
              "product_name" => %{"type" => "string"},
              "brand" => %{"type" => "string"},
              "price" => %{
                "type" => "object",
                "properties" => %{
                  "currency" => %{"type" => "string"},
                  "list_price" => %{"type" => "number"},
                  "sale_price" => %{"type" => "number"}
                },
                "required" => ["currency", "list_price", "sale_price"],
                "additionalProperties" => false
              },
              "specifications" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "name" => %{"type" => "string"},
                    "value" => %{"type" => "string"}
                  },
                  "required" => ["name", "value"],
                  "additionalProperties" => false
                }
              },
              "shipping" => %{"type" => "string"},
              "returns" => %{"type" => "string"},
              "rating" => %{
                "type" => "object",
                "properties" => %{
                  "score" => %{"type" => "number"},
                  "review_count" => %{"type" => "integer"}
                },
                "required" => ["score", "review_count"],
                "additionalProperties" => false
              },
              "faq" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "question" => %{"type" => "string"},
                    "answer" => %{"type" => "string"}
                  },
                  "required" => ["question", "answer"],
                  "additionalProperties" => false
                }
              }
            },
            "required" => [
              "product_name",
              "brand",
              "price",
              "specifications",
              "shipping",
              "returns",
              "rating",
              "faq"
            ],
            "additionalProperties" => false
          }
        }
      }
    },
    %{
      input: """
      Architecture Notes
      System components:
      - API ingress receives request envelopes and validates shape.
      - Admission controller estimates tokens and places requests into capacity queues.
      - Batch builder groups compatible requests by model, endpoint, and payload limits.
      - Dispatcher uploads JSONL files and transitions batch state machine.
      - Retriever polls provider status and downloads result files when complete.
      Operational guidance:
      Keep dashboards focused on admission lag, queue depth, dispatch success rate,
      provider HTTP error classes, and delivery retry backlog.
      When diagnosing incidents, start with the timeline of state transitions and
      compare expected token budgets with observed usage by model.
      """
    }
  ]

  def run do
    IO.puts("Sending #{@count} large requests to #{@api_url}")
    IO.puts("  endpoint: #{@url}")
    IO.puts("  model: #{@model}")
    IO.puts("  input_bytes/request: #{@payload_bytes}")
    IO.puts("  concurrency: 3")

    start_ms = System.monotonic_time(:millisecond)

    results =
      1..@count
      |> Task.async_stream(
        fn i ->
          req = build_request(i)

          case Req.post(@api_url, json: req, headers: [{"content-type", "application/json"}]) do
            {:ok, %{status: status}} ->
              {:ok, status}

            {:error, reason} ->
              {:error, reason}
          end
        end,
        max_concurrency: 3,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, reason}
      end)

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
    scenario = payload_scenario(i)

    %{
      "custom_id" => "big_#{i}_#{System.unique_integer([:positive])}",
      "url" => @url,
      "method" => "POST",
      "body" => build_body(scenario),
      "delivery_config" => %{
        "type" => "webhook",
        "webhook_url" => @webhook_url
      }
    }
  end

  defp payload_scenario(i) do
    Enum.at(@payload_scenarios, rem(i - 1, length(@payload_scenarios)))
  end

  defp build_body(%{input: input} = scenario) do
    base = %{
      "model" => @model,
      "input" => sized_payload(input, @payload_bytes)
    }

    case Map.get(scenario, :text) do
      nil -> base
      text -> Map.put(base, "text", text)
    end
  end

  defp sized_payload(template, target_bytes) when target_bytes <= 0, do: ""

  defp sized_payload(template, target_bytes) do
    block = String.trim(template) <> "\n\n"
    block_bytes = byte_size(block)
    repeats = max(1, div(target_bytes + block_bytes - 1, block_bytes))

    block
    |> String.duplicate(repeats)
    |> binary_part(0, target_bytes)
  end
end

BigPayloadScript.run()
