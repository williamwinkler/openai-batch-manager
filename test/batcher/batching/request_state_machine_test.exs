defmodule Batcher.Batching.RequestStateMachineTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  import Batcher.Generator

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
    test "allows retry_delivery from non-delivering states when response payload exists" do
      retryable_states = [
        :openai_processed,
        :delivered,
        :failed,
        :delivery_failed,
        :expired,
        :cancelled
      ]

      for state <- retryable_states do
        request =
          generate(
            seeded_request(
              state: state,
              response_payload: %{"output" => "response"},
              delivery_config: %{
                "type" => "webhook",
                "webhook_url" => "https://example.com/webhook"
              }
            )
          )

        updated_request =
          request
          |> Ash.Changeset.for_update(:retry_delivery)
          |> Ash.update!()

        assert updated_request.state == :openai_processed
      end
    end

    test "rejects retry_delivery when request has no response payload" do
      request =
        generate(
          seeded_request(
            state: :delivery_failed,
            response_payload: nil,
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      assert_raise Ash.Error.Invalid, fn ->
        request
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()
      end
    end

    test "rejects retry_delivery when request is delivering" do
      request =
        generate(
          seeded_request(
            state: :delivering,
            response_payload: %{"output" => "response"},
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      assert_raise Ash.Error.Invalid, fn ->
        request
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()
      end
    end

    test "rejects retry_delivery when parent batch is delivering" do
      batch =
        seeded_batch(state: :delivering, model: "gpt-4o-mini", url: "/v1/responses")
        |> generate()

      request =
        generate(
          seeded_request(
            batch_id: batch.id,
            state: :delivery_failed,
            response_payload: %{"output" => "response"},
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          )
        )

      assert {:error, %Ash.Error.Invalid{} = error} = Batching.retry_request_delivery(request)

      assert Exception.message(error) =~
               "Batch cannot redeliver while it is currently delivering"
    end

    test "allows RabbitMQ retry even when publisher is disconnected" do
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

      updated_request =
        request
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()

      assert updated_request.state == :openai_processed
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
end
