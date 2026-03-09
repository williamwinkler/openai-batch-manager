defmodule Batcher.Batching.RequestCreationTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Settings

  import Batcher.Generator

  describe "Batcher.Batching.create_request" do
    test "creates a request with valid attributes" do
      batch = generate(batch())
      custom_id = "req_123"

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: custom_id,
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert is_integer(request.id)
      assert request.state == :pending
      assert request.custom_id == custom_id
      assert request.batch_id == batch.id
      assert request.url == batch.url
      assert request.model == batch.model
      assert request.delivery_config["type"] == "webhook"
      assert request.delivery_config["webhook_url"] == "https://example.com/webhook"
      assert request.request_payload
      assert request.request_payload_size > 0
      assert request.created_at
      assert request.updated_at
    end

    test "creates a request with rabbitmq delivery using default exchange" do
      batch = generate(batch())
      custom_id = "req_456"

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: custom_id,
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "results_queue"
          }
        })

      assert request.delivery_config["type"] == "rabbitmq"
      assert request.delivery_config["rabbitmq_queue"] == "results_queue"
    end

    test "can't create request with duplicate custom_id in same batch" do
      batch = generate(batch())
      custom_id = "duplicate_id"

      {:ok, _request1} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: custom_id,
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_request!(%{
          batch_id: batch.id,
          custom_id: custom_id,
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test2", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook2"
          }
        })
      end
    end

    test "can't create request with same custom_id in different batch" do
      batch1 = generate(batch())
      batch2 = generate(batch())
      custom_id = "same_id"

      {:ok, request1} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: custom_id,
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert_raise Ash.Error.Invalid, fn ->
        Batching.create_request!(%{
          batch_id: batch2.id,
          custom_id: custom_id,
          url: batch2.url,
          model: batch2.model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: batch2.model},
            method: "POST",
            url: batch2.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })
      end

      assert request1.batch_id == batch1.id
    end

    test "can't create request when batch is not in building state" do
      batch = generate(seeded_batch(state: :uploading))

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "test_state",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "test_state",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and error_reason(err) == :batch_not_building
             end)
    end

    test "returns error when batch_id doesn't exist" do
      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: 999_999,
          custom_id: "test_missing",
          url: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{
            custom_id: "test_missing",
            body: %{input: "test", model: "gpt-4o-mini"},
            method: "POST",
            url: "/v1/responses"
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and error_reason(err) == :batch_not_found
             end)
    end

    test "can't create request when batch is full (using test limit of 5 requests)" do
      batch = generate(batch())

      # Create 5 requests to fill the batch (test limit is 5)
      for i <- 1..5 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "req_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: %{
              custom_id: "req_#{i}",
              body: %{input: "test #{i}", model: batch.model},
              method: "POST",
              url: batch.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      # Try to create one more request - should fail
      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_6",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_6",
            body: %{input: "test 6", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and error_reason(err) == :batch_full
             end)
    end

    test "can't create request when incoming payload would exceed batch size limit (using test limit of 1MB)" do
      batch = generate(batch())
      # Ensure this test hits the size guard, not the token-capacity guard.
      Settings.upsert_model_override!(batch.model, 10_000_000)

      large_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # Keep the current batch below 1MB.
      for i <- 1..2 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "large_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(large_payload_base, :custom_id, "large_#{i}"),
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      # This request would push the batch over the size limit.
      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "large_3",
          url: batch.url,
          model: batch.model,
          request_payload: Map.put(large_payload_base, :custom_id, "large_3"),
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and error_reason(err) == :batch_size_would_exceed
             end)
    end

    test "can't create request when request_payload custom_id doesn't match" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "different_id",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :custom_id and String.contains?(err.message, "does not match")
             end)
    end

    test "can't create request when request_payload model doesn't match" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: "different-model"},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :model and String.contains?(err.message, "does not match")
             end)
    end

    test "can't create request when request_payload url doesn't match" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: "/v1/chat/completions"
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :url and String.contains?(err.message, "does not match")
             end)
    end

    test "can't create request with webhook delivery but missing webhook_url" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config and
                 String.contains?(err.message, "webhook_url is required")
             end)
    end

    test "can't create request with invalid webhook URL" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "not-a-valid-url"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config and
                 String.contains?(err.message, "valid HTTP/HTTPS URL")
             end)
    end

    test "can create request with docker-style webhook hostname" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_docker_host",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_docker_host",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "http://python-http-webhook:8080/webhook"
          }
        })

      assert request.delivery_config["webhook_url"] == "http://python-http-webhook:8080/webhook"
    end

    test "can't create request with rabbitmq delivery but missing queue" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config and
                 String.contains?(err.message, "rabbitmq_queue is required")
             end)
    end

    test "can't create request with rabbitmq_exchange (no longer supported)" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "test_exchange"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config and
                 String.contains?(err.message, "rabbitmq_exchange is no longer supported")
             end)
    end

    test "can't create request with empty rabbitmq_queue when using default exchange" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => ""
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config
             end)
    end

    test "can't create request with unsupported delivery type" do
      batch = generate(batch())

      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_123",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_123",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "unsupported_type"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_config and
                 String.contains?(err.message, "unsupported delivery type")
             end)
    end

    test "rejects request with both rabbitmq exchange and queue" do
      batch = generate(batch())

      result =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_rabbitmq_full",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_rabbitmq_full",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "my_exchange",
            "rabbitmq_routing_key" => "results.completed",
            "rabbitmq_queue" => "results_queue"
          }
        })

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "can create request with rabbitmq queue only" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_rabbitmq_queue_only",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_rabbitmq_queue_only",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "results_queue"
          }
        })

      assert request.delivery_config["type"] == "rabbitmq"
      assert request.delivery_config["rabbitmq_queue"] == "results_queue"
    end
  end

  defp error_reason(%{private_vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{private_vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)

  defp error_reason(%{vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)

  defp error_reason(_), do: nil
end
