defmodule Batcher.Batching.RequestTest do
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

  describe "Batcher.Batching.get_request_by_custom_id" do
    test "finds request by batch_id and custom_id" do
      batch = generate(batch())
      custom_id = "find_me"

      {:ok, created_request} =
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

      found_request = Batching.get_request_by_custom_id!(batch.id, custom_id)

      assert found_request.id == created_request.id
      assert found_request.custom_id == custom_id
      assert found_request.batch_id == batch.id
    end

    test "throws error if request not found" do
      batch = generate(batch())

      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_request_by_custom_id!(batch.id, "nonexistent")
      end
    end
  end

  describe "Batcher.Batching.list_requests_in_batch" do
    test "lists all requests in a batch" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      # Create requests in batch1
      {:ok, _req1} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: "req1",
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: "req1",
            body: %{input: "test1", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, _req2} =
        Batching.create_request(%{
          batch_id: batch1.id,
          custom_id: "req2",
          url: batch1.url,
          model: batch1.model,
          request_payload: %{
            custom_id: "req2",
            body: %{input: "test2", model: batch1.model},
            method: "POST",
            url: batch1.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Create request in batch2
      {:ok, _req3} =
        Batching.create_request(%{
          batch_id: batch2.id,
          custom_id: "req3",
          url: batch2.url,
          model: batch2.model,
          request_payload: %{
            custom_id: "req3",
            body: %{input: "test3", model: batch2.model},
            method: "POST",
            url: batch2.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, requests} = Batching.list_requests_in_batch(batch1.id)

      assert length(requests) == 2
      assert Enum.all?(requests, fn req -> req.batch_id == batch1.id end)
    end

    test "returns empty list for batch with no requests" do
      batch = generate(batch())

      {:ok, requests} = Batching.list_requests_in_batch(batch.id)

      assert requests == []
    end
  end

  describe "Batcher.Batching.count_requests_for_search" do
    test "counts requests using the same query semantics as search" do
      batch = generate(batch())

      for i <- 1..3 do
        {:ok, _request} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "needle-#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: %{
              custom_id: "needle-#{i}",
              body: %{input: "count test", model: batch.model},
              method: "POST",
              url: batch.url
            },
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      {:ok, page} = Batching.search_requests("needle-", page: [limit: 2, count: true])

      {:ok, count_page} =
        Batching.count_requests_for_search("needle-", page: [limit: 1, count: true])

      assert count_page.count == page.count
    end

    test "respects batch_id filtering" do
      batch1 = generate(batch())
      batch2 = generate(batch())

      _ = generate_many(request(batch_id: batch1.id), 2)
      _ = generate_many(request(batch_id: batch2.id), 4)

      {:ok, page} =
        Batching.search_requests(
          "",
          %{batch_id: batch2.id, sort_input: "-created_at"},
          page: [limit: 2, count: true]
        )

      {:ok, count_page} =
        Batching.count_requests_for_search(
          "",
          %{batch_id: batch2.id},
          page: [limit: 1, count: true]
        )

      assert count_page.count == page.count
      assert count_page.count == 4
    end
  end

  describe "Batcher.Batching.Request.begin_processing" do
    test "transitions request from pending to openai_processing" do
      request = generate(request())

      assert request.state == :pending

      updated_request =
        request
        |> Ash.Changeset.for_update(:begin_processing)
        |> Ash.update!()

      assert updated_request.state == :openai_processing
    end

    test "can't transition from invalid state" do
      invalid_states = [:openai_processed, :delivering, :delivered, :failed, :expired, :cancelled]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:begin_processing)
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.bulk_begin_processing" do
    test "transitions multiple requests to openai_processing" do
      batch = generate(batch())
      requests = generate_many(request(batch_id: batch.id), 3)

      for request <- requests do
        assert request.state == :pending
      end

      for request <- requests do
        updated_request =
          request
          |> Ash.Changeset.for_update(:bulk_begin_processing)
          |> Ash.update!()

        assert updated_request.state == :openai_processing
      end
    end
  end

  describe "Batcher.Batching.Request.complete_processing" do
    test "transitions request from openai_processing to openai_processed with response" do
      request = generate(seeded_request(state: :openai_processing))

      response_payload = %{
        "output" => "This is a test response",
        "status_code" => 200
      }

      updated_request =
        request
        |> Ash.Changeset.for_update(:complete_processing, %{response_payload: response_payload})
        |> Ash.update!()

      assert updated_request.state == :openai_processed
      assert updated_request.response_payload == response_payload
    end

    test "can't transition from invalid state" do
      invalid_states = [
        :pending,
        :openai_processed,
        :delivering,
        :delivered,
        :failed,
        :expired,
        :cancelled
      ]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:complete_processing, %{
            response_payload: %{"output" => "test"}
          })
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.begin_delivery" do
    test "transitions request from openai_processed to delivering" do
      request = generate(seeded_request(state: :openai_processed))

      updated_request =
        request
        |> Ash.Changeset.for_update(:begin_delivery)
        |> Ash.update!()

      assert updated_request.state == :delivering
    end

    test "can't transition from invalid state" do
      invalid_states = [
        :pending,
        :openai_processing,
        :delivering,
        :delivered,
        :failed,
        :expired,
        :cancelled
      ]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:begin_delivery)
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.complete_delivery" do
    test "transitions request from delivering to delivered" do
      request = generate(seeded_request(state: :delivering))

      updated_request =
        request
        |> Ash.Changeset.for_update(:complete_delivery)
        |> Ash.update!()

      assert updated_request.state == :delivered
    end

    test "can't transition from invalid state" do
      invalid_states = [
        :pending,
        :openai_processing,
        :openai_processed,
        :delivered,
        :failed,
        :expired,
        :cancelled
      ]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:complete_delivery)
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.mark_failed" do
    test "transitions request to failed with error message" do
      request = generate(seeded_request(state: :openai_processing))
      error_msg = "Processing failed"

      updated_request =
        request
        |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
        |> Ash.update!()

      assert updated_request.state == :failed
      assert updated_request.error_msg == error_msg
    end

    test "can mark failed from multiple states" do
      # Note: :delivering uses mark_delivery_failed, not mark_failed
      states = [:pending, :openai_processing, :openai_processed]

      for state <- states do
        request = generate(seeded_request(state: state))

        updated_request =
          request
          |> Ash.Changeset.for_update(:mark_failed, %{error_msg: "Failed from #{state}"})
          |> Ash.update!()

        assert updated_request.state == :failed
      end
    end

    test "mark_delivery_failed transitions from delivering to delivery_failed" do
      request = generate(seeded_request(state: :delivering))

      updated_request =
        request
        |> Ash.Changeset.for_update(:mark_delivery_failed, %{})
        |> Ash.update!()

      assert updated_request.state == :delivery_failed
    end

    test "can't mark failed from terminal states" do
      terminal_states = [:delivered, :failed, :delivery_failed, :expired, :cancelled]

      for state <- terminal_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:mark_failed, %{error_msg: "Failed"})
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.mark_expired" do
    test "transitions request to expired with error message" do
      request = generate(seeded_request(state: :pending))
      error_msg = "Request expired"

      updated_request =
        request
        |> Ash.Changeset.for_update(:mark_expired, %{error_msg: error_msg})
        |> Ash.update!()

      assert updated_request.state == :expired
      assert updated_request.error_msg == error_msg
    end

    test "can mark expired from pending and openai_processing states" do
      states = [:pending, :openai_processing]

      for state <- states do
        request = generate(seeded_request(state: state))

        updated_request =
          request
          |> Ash.Changeset.for_update(:mark_expired, %{error_msg: "Expired from #{state}"})
          |> Ash.update!()

        assert updated_request.state == :expired
      end
    end

    test "can't mark expired from invalid state" do
      invalid_states = [:openai_processed, :delivering, :delivered, :failed, :expired, :cancelled]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:mark_expired, %{error_msg: "Expired"})
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.cancel" do
    test "can cancel from active states" do
      cancellable_states = [:pending, :openai_processing, :openai_processed, :delivering]

      for state <- cancellable_states do
        request = generate(seeded_request(state: state))

        updated_request =
          request
          |> Ash.Changeset.for_update(:cancel)
          |> Ash.update!()

        assert updated_request.state == :cancelled
      end
    end

    test "can't cancel from invalid state" do
      invalid_states = [
        :delivered,
        :failed,
        :expired,
        :cancelled
      ]

      for state <- invalid_states do
        request = generate(seeded_request(state: state))

        assert_raise Ash.Error.Invalid, fn ->
          request
          |> Ash.Changeset.for_update(:cancel)
          |> Ash.update!()
        end
      end
    end
  end

  describe "Batcher.Batching.Request.retry_delivery" do
    test "blocks RabbitMQ retry when publisher is disconnected" do
      if pid = Process.whereis(Batcher.RabbitMQ.Publisher) do
        Process.exit(pid, :kill)
      end

      request =
        generate(
          seeded_request(
            state: :delivery_failed,
            delivery_config: %{"type" => "rabbitmq", "rabbitmq_queue" => "batch_results"},
            response_payload: %{"output" => "response"}
          )
        )

      assert_raise Ash.Error.Invalid, fn ->
        request
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()
      end
    end
  end

  describe "pubsub notifications" do
    test "state transitions publish both global and per-request state_changed topics" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "pubsub-state-change",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "pubsub-state-change",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      BatcherWeb.Endpoint.subscribe("requests:state_changed")
      request_id = request.id
      request_topic = "requests:state_changed:#{request_id}"
      BatcherWeb.Endpoint.subscribe(request_topic)

      request
      |> Ash.Changeset.for_update(:begin_processing)
      |> Ash.update!()

      assert_receive %{topic: "requests:state_changed", payload: %{data: %{id: ^request_id}}}

      assert_receive %{topic: ^request_topic, payload: %{data: %{id: ^request_id}}}
    end
  end

  describe "relationship loading" do
    test "loads request.delivery_attempts relationship" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Create delivery attempts
      changeset1 =
        Batcher.Batching.RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          outcome: :connection_error,
          error_msg: "First attempt failed",
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      {:ok, _attempt1} = Ash.create(changeset1)

      changeset2 =
        Batcher.Batching.RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          outcome: :success,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
        })

      {:ok, _attempt2} = Ash.create(changeset2)

      # Load request with delivery attempts
      request = Ash.load!(request, [:delivery_attempts])

      assert length(request.delivery_attempts) == 2

      failed_attempt = Enum.find(request.delivery_attempts, &(&1.outcome != :success))
      assert failed_attempt.error_msg == "First attempt failed"

      successful_attempt = Enum.find(request.delivery_attempts, &(&1.outcome == :success))
      assert successful_attempt.outcome == :success
    end

    test "loads request.batch relationship" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_1",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_1",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Load request with batch
      request = Ash.load!(request, [:batch])

      assert request.batch.id == batch.id
      assert request.batch.model == batch.model
      assert request.batch.url == batch.url
    end
  end

  defp error_reason(%{private_vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{private_vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)

  defp error_reason(%{vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)

  defp error_reason(_), do: nil
end
