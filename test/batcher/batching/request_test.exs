defmodule Batcher.Batching.RequestTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert is_integer(request.id)
      assert request.state == :pending
      assert request.custom_id == custom_id
      assert request.batch_id == batch.id
      assert request.url == batch.url
      assert request.model == batch.model
      assert request.delivery_type == :webhook
      assert request.webhook_url == "https://example.com/webhook"
      assert request.request_payload
      assert request.request_payload_size > 0
      assert request.created_at
      assert request.updated_at
    end

    test "creates a request with rabbitmq delivery" do
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
          delivery: %{
            type: "rabbitmq",
            rabbitmq_queue: "results_queue"
          }
        })

      assert request.delivery_type == :rabbitmq
      assert request.rabbitmq_queue == "results_queue"
      assert request.webhook_url == nil
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook2"
          }
        })
      end
    end

    test "can create request with same custom_id in different batch" do
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      {:ok, request2} =
        Batching.create_request(%{
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert request1.custom_id == request2.custom_id
      assert request1.batch_id != request2.batch_id
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and String.contains?(err.message, "not in building state")
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and String.contains?(err.message, "batch not found")
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
            delivery: %{
              type: "webhook",
              webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and String.contains?(err.message, "full")
             end)
    end

    test "can't create request when batch size exceeds limit (using test limit of 1MB)" do
      batch = generate(batch())

      # Create requests with large payloads to exceed 1MB limit
      # Each request payload is ~350KB, so 3 requests = ~1.05MB > 1MB limit
      # This stays under the 5 request count limit
      large_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # Create 3 requests with large payloads (total ~1.05MB > 1MB limit)
      for i <- 1..3 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "large_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(large_payload_base, :custom_id, "large_#{i}"),
            delivery: %{
              type: "webhook",
              webhook_url: "https://example.com/webhook"
            }
          })
      end

      # Try to create one more request - should fail due to size limit
      {:error, %Ash.Error.Invalid{} = error} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "large_4",
          url: batch.url,
          model: batch.model,
          request_payload: Map.put(large_payload_base, :custom_id, "large_4"),
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :batch_id and String.contains?(err.message, "exceeds")
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :webhook_url and String.contains?(err.message, "required")
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
          delivery: %{
            type: "webhook",
            webhook_url: "not-a-valid-url"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :webhook_url and String.contains?(err.message, "valid url")
             end)
    end

    test "can't create request with rabbitmq delivery but missing rabbitmq_queue" do
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
          delivery: %{
            type: "rabbitmq"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :rabbitmq_queue and String.contains?(err.message, "required")
             end)
    end

    test "can't create request with empty rabbitmq_queue" do
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
          delivery: %{
            type: "rabbitmq",
            rabbitmq_queue: ""
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :rabbitmq_queue and String.contains?(err.message, "required")
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
          delivery: %{
            type: "unsupported_type"
          }
        })

      assert Enum.any?(error.errors, fn err ->
               err.field == :delivery_type and
                 String.contains?(err.message, "Unsupported type")
             end)
    end

    test "can create request with rabbitmq delivery and optional exchange" do
      batch = generate(batch())

      {:ok, request} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "req_rabbitmq_exchange",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "req_rabbitmq_exchange",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery: %{
            type: "rabbitmq",
            rabbitmq_queue: "results_queue",
            rabbitmq_exchange: "my_exchange"
          }
        })

      assert request.delivery_type == :rabbitmq
      assert request.rabbitmq_queue == "results_queue"
      assert request.rabbitmq_exchange == "my_exchange"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
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
      invalid_states = [:pending, :openai_processed, :delivering, :delivered, :failed, :expired, :cancelled]

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
      invalid_states = [:pending, :openai_processing, :delivering, :delivered, :failed, :expired, :cancelled]

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
      invalid_states = [:pending, :openai_processing, :openai_processed, :delivered, :failed, :expired, :cancelled]

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
      states = [:pending, :openai_processing, :openai_processed, :delivering]

      for state <- states do
        request = generate(seeded_request(state: state))

        updated_request =
          request
          |> Ash.Changeset.for_update(:mark_failed, %{error_msg: "Failed from #{state}"})
          |> Ash.update!()

        assert updated_request.state == :failed
      end
    end

    test "can't mark failed from terminal states" do
      terminal_states = [:delivered, :failed, :expired, :cancelled]

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
    test "transitions request from pending to cancelled" do
      request = generate(seeded_request(state: :pending))

      updated_request =
        request
        |> Ash.Changeset.for_update(:cancel)
        |> Ash.update!()

      assert updated_request.state == :cancelled
    end

    test "can't cancel from invalid state" do
      invalid_states = [:openai_processing, :openai_processed, :delivering, :delivered, :failed, :expired, :cancelled]

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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      # Create delivery attempts
      changeset1 =
        Batcher.Batching.RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: false,
          error_msg: "First attempt failed"
        })
        |> Ash.Changeset.force_change_attribute(:type, :webhook)

      {:ok, _attempt1} = Ash.create(changeset1)

      changeset2 =
        Batcher.Batching.RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true
        })
        |> Ash.Changeset.force_change_attribute(:type, :webhook)

      {:ok, _attempt2} = Ash.create(changeset2)

      # Load request with delivery attempts
      request = Ash.load!(request, [:delivery_attempts])

      assert length(request.delivery_attempts) == 2

      failed_attempt = Enum.find(request.delivery_attempts, &(!&1.success))
      assert failed_attempt.error_msg == "First attempt failed"

      successful_attempt = Enum.find(request.delivery_attempts, &(&1.success))
      assert successful_attempt.success == true
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
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      # Load request with batch
      request = Ash.load!(request, [:batch])

      assert request.batch.id == batch.id
      assert request.batch.model == batch.model
      assert request.batch.url == batch.url
    end
  end
end
