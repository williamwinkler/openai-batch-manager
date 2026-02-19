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
  @payload_bytes 5_460
  @rabbitmq_queue "batch_results"
  @payload_scenarios [
    %{
      input: """
      Incident Report
      Service: batch-orchestrator
      Date: 2026-02-10
      Summary: Queue latency spike between 14:05 and 14:37 UTC.
      Symptoms:
      - p95 enqueue-to-dispatch rose from 900ms to 12.4s
      - 0.7% duplicate deliveries
      - Capacity controller oscillated every 20-30 seconds
      Findings:
      1) Upstream retries surged during provider degradation.
      2) Download workers saturated the pool.
      3) Retry backoff lacked jitter.
      Action items:
      - Add per-model fairness queue
      - Add jittered exponential backoff
      - Split dispatch and retrieval workers
      """
    },
    %{
      input: """
      Product Requirements Document
      Feature: Capacity-Aware Admission
      Goal:
      Admit requests using model token budgets while maximizing throughput.
      Constraints:
      - Preserve per-tenant FIFO fairness
      - Deterministic, auditable decisions
      - Idempotent transitions under retry
      Non-goals:
      - Dynamic model selection at runtime
      - Automatic prompt rewriting
      Acceptance criteria:
      - 99% admitted within 5 minutes under steady load
      - Graceful degradation under lower provider limits
      - Operators can inspect waiting reason and last capacity check
      """
    },
    %{
      input: """
      Customer Support Conversation
      Agent: Please share request id and timestamp.
      Customer: req_9fc21 around 08:13 UTC returned empty.
      Agent: Batch completed, but one item failed validation.
      Customer: Why if the batch completed?
      Agent: Batch-level completion can include item-level failures.
      Customer: Can I retry just that one item?
      Agent: Yes, resubmit with a new custom_id for safe dedupe.
      Customer: Can retries handle endpoint downtime?
      Agent: Yes, exponential backoff up to 24 hours.
      """
    },
    %{
      input: """
      Security Triage Task
      Analyze this incident and return structured data matching the response schema.
      Evidence:
      - Token rotation failed for one tenant after deploy.
      - 342 requests were rejected with invalid_signature in 18 minutes.
      - No unauthorized reads detected in audit logs.
      - Mitigation was manual key re-issuance.
      - Follow-up: key lifecycle automation and deploy safeguards.
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
      <p class="subtitle">Built for multi-day treks.</p>
      <div class="pricing">
        <span class="price">$149.00</span>
        <span class="sale">Now $119.00</span>
      </div>
      <ul class="specs">
        <li>Capacity: 38 liters</li>
        <li>Weight: 0.92 kg</li>
        <li>Material: Ripstop nylon</li>
      </ul>
      <div class="shipping">Ships in 2-3 business days from Denver, CO.</div>
      <div class="returns">30-day returns.</div>
      <div class="rating">4.7 out of 5 (1,284 reviews)</div>
      <div class="faq">
        <p>Q: Is it carry-on compatible?</p>
        <p>A: Yes.</p>
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
      - API ingress validates request envelopes.
      - Admission controller estimates tokens and queues requests.
      - Batch builder groups by model, endpoint, and limits.
      - Dispatcher uploads JSONL and transitions batch state.
      - Retriever polls status and downloads results.
      Operational guidance:
      Monitor admission lag, queue depth, dispatch success, provider HTTP errors,
      and delivery retry backlog. Diagnose via state-transition timeline and
      expected vs observed token usage by model.
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
        "type" => "rabbitmq",
        "rabbitmq_queue" => @rabbitmq_queue
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
