defmodule Batcher.Batching.Actions.DeliverTest do
  use Batcher.DataCase, async: false
  use AMQP

  alias Batcher.Batching
  alias Batcher.RabbitMQ.FakePublisher

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()

    # Setup RabbitMQ if available
    rabbitmq_url =
      case System.get_env("RABBITMQ_URL") do
        nil -> "amqp://guest:guest@localhost:5672"
        "" -> "amqp://guest:guest@localhost:5672"
        url -> url
      end

    rabbitmq_context =
      case Connection.open(rabbitmq_url) do
        {:ok, conn} ->
          {:ok, chan} = Channel.open(conn)
          test_queue = "test_deliver_#{System.unique_integer([:positive])}"

          {:ok, _} = Queue.declare(chan, test_queue, durable: true)

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

          %{
            rabbitmq_available: true,
            rabbitmq_url: rabbitmq_url,
            queue: test_queue,
            conn: conn,
            chan: chan
          }

        {:error, _reason} ->
          %{rabbitmq_available: false, rabbitmq_url: rabbitmq_url}
      end

    {:ok, Map.merge(%{server: server}, rabbitmq_context)}
  end

  describe "deliver action" do
    test "successfully delivers webhook with 200 status", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response", "status" => "success"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Mock successful webhook response
      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after =
        Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts, :batch])

      assert request_after.state == :delivered
      assert request_after.delivery_attempt_count == 1

      # Verify delivery attempt was recorded
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :success
      assert attempt.delivery_config["type"] == "webhook"
      assert attempt.error_msg == nil

      # Trigger batch completion check (normally done by AshOban) and verify state
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivered
    end

    test "successfully delivers webhook with 201 status", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{created: true}, 201)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert request_after.state == :delivered
    end

    test "saves response body in error_msg on delivery_attempt (not request) on 4xx error", %{
      server: server
    } do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      error_response = %{"error" => "Invalid request", "code" => "INVALID"}
      expect_json_response(server, :post, "/webhook", error_response, 400)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts])

      assert request_after.state == :delivery_failed
      assert request_after.delivery_attempt_count == 1
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Verify delivery attempt was recorded with failure and contains error details
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :http_status_not_2xx
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
      assert attempt.error_msg =~ "INVALID"
    end

    test "saves response body in error_msg on delivery_attempt (not request) on 5xx error", %{
      server: server
    } do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      error_response = %{"error" => "Internal server error", "message" => "Something went wrong"}
      expect_json_response(server, :post, "/webhook", error_response, 500)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Verify delivery attempt was recorded with failure and contains error details
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome != :success
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
    end

    test "handles connection refused error" do
      # Use an invalid URL that will cause connection refused
      # Use a non-routable IP address to ensure connection failure
      webhook_url = "http://192.0.2.1:8080/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      result =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      # Should handle connection error gracefully
      assert {:ok, request_after} = result
      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Error details are stored on delivery_attempt
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome != :success
      assert attempt.error_msg != nil
    end

    test "successfully delivers to RabbitMQ queue" do
      # Start fake publisher that returns :ok for all publishes
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      response_payload = %{"output" => "test response", "status" => "success"}

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: response_payload
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after =
        Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts, :batch])

      assert request_after.state == :delivered
      assert request_after.delivery_attempt_count == 1

      # Verify delivery attempt was recorded
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :success
      assert attempt.delivery_config["type"] == "rabbitmq"
      assert attempt.error_msg == nil

      # Trigger batch completion check (normally done by AshOban) and verify state
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "successfully delivers to RabbitMQ exchange with rabbitmq_routing_key" do
      # Start fake publisher that returns :ok for all publishes
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      response_payload = %{"output" => "test response", "status" => "success"}

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "test_exchange",
            "rabbitmq_routing_key" => "test.routing.key"
          },
          response_payload: response_payload
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts, :batch])

      assert request_after.state == :delivered
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :success

      # Trigger batch completion check (normally done by AshOban) and verify state
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "delivers to custom exchange with routing_key" do
      # Start fake publisher that returns :ok for all publishes
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      response_payload = %{"output" => "test response", "status" => "success"}

      # Custom exchange mode: exchange + routing_key (no queue)
      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "test_exchange",
            "rabbitmq_routing_key" => "priority.routing.key"
          },
          response_payload: response_payload
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert request_after.state == :delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ queue_not_found error" do
      # Start fake publisher that returns queue_not_found error
      {:ok, _pid} =
        FakePublisher.start_link(
          responses: %{{"", "non_existent_queue"} => {:error, :queue_not_found}}
        )

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "non_existent_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      assert request_after.error_msg == nil

      # Error details are stored on delivery_attempt
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :queue_not_found
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "Queue not found"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ exchange_not_found error" do
      # Start fake publisher that returns exchange_not_found error
      {:ok, _pid} =
        FakePublisher.start_link(
          responses: %{{"non_existent_exchange", "test.key"} => {:error, :exchange_not_found}}
        )

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_exchange" => "non_existent_exchange",
            "rabbitmq_routing_key" => "test.key"
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :exchange_not_found
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "Exchange not found"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ not_connected error" do
      # Start fake publisher that returns not_connected error
      {:ok, _pid} =
        FakePublisher.start_link(responses: %{{"", "test_queue"} => {:error, :not_connected}})

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :connection_error
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "Not connected to RabbitMQ"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ timeout error" do
      # Start fake publisher that returns timeout error
      {:ok, _pid} =
        FakePublisher.start_link(responses: %{{"", "test_queue"} => {:error, :timeout}})

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :timeout
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "Publish confirmation timeout"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ nack error" do
      # Start fake publisher that returns nack error
      {:ok, _pid} =
        FakePublisher.start_link(responses: %{{"", "test_queue"} => {:error, :nack}})

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :other
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "Message was nacked by broker"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "handles RabbitMQ other error types" do
      # Start fake publisher that returns unknown error
      {:ok, _pid} =
        FakePublisher.start_link(responses: %{{"", "test_queue"} => {:error, :unknown_error}})

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :other
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "RabbitMQ error"

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "transitions batch to done when all RabbitMQ requests are delivered" do
      # Start fake publisher that returns :ok for all publishes
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      response_payload = %{"output" => "test response"}

      # Create two requests
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: response_payload
        )
        |> generate()

      # Deliver first request
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request1)
        |> Ash.run_action()

      # Deliver second request (should trigger batch completion)
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request2)
        |> Ash.run_action()

      # Trigger batch completion check (normally done by AshOban)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "transitions batch to partially_delivered when some RabbitMQ requests succeed and some fail" do
      # Start fake publisher with mixed responses
      {:ok, _pid} =
        FakePublisher.start_link(
          responses: %{
            {"", "success_queue"} => :ok,
            {"", "fail_queue"} => {:error, :queue_not_found}
          }
        )

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      response_payload = %{"output" => "test response"}

      # Create two requests - one will succeed, one will fail
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "success_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "fail_queue",
            "rabbitmq_exchange" => ""
          },
          response_payload: response_payload
        )
        |> generate()

      # Deliver first request (success)
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request1)
        |> Ash.run_action()

      # Deliver second request (failure)
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request2)
        |> Ash.run_action()

      # Trigger batch completion check (normally done by AshOban)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "uses rabbitmq_routing_key when both queue and routing_key are provided (legacy support)" do
      # Start fake publisher
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Legacy format with routing_key (not rabbitmq_routing_key) still works
      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "fallback_queue",
            "rabbitmq_exchange" => "",
            "routing_key" => "legacy_routing_key"
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert request_after.state == :delivered

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "raises error when queue is missing for RabbitMQ delivery" do
      # Start fake publisher so we get past the "not configured" check
      {:ok, _pid} = FakePublisher.start_link()

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq"
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      result =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result

      # Cleanup
      GenServer.stop(Batcher.RabbitMQ.Publisher)
    end

    test "fails delivery when RabbitMQ publisher is not configured" do
      # Do NOT start fake publisher - simulating RabbitMQ not configured
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue"
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert request_after.state == :delivery_failed
      assert request_after.error_msg == nil

      # Error details are stored on delivery_attempt
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome == :rabbitmq_not_configured
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "RabbitMQ is not configured"
    end

    test "raises error when webhook_url is missing" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook"
          },
          response_payload: %{"output" => "test"}
        )
        |> generate()

      result =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "raises error when response_payload is missing", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: nil
        )
        |> generate()

      result =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "transitions batch to delivering when first request delivers", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Add a second request still waiting for delivery
      # This ensures the batch stays in :delivering after first request completes
      _pending_request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, _request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      # Reload batch to check state - should stay in delivering since second request is pending
      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :delivering
    end

    test "transitions batch to done when all requests are delivered", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create two requests
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Set up webhook responses for both requests
      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      # Deliver first request
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request1)
        |> Ash.run_action()

      # Set up webhook response again for second request
      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      # Deliver second request (should trigger batch completion)
      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request2)
        |> Ash.run_action()

      # Trigger batch completion check (normally done by AshOban)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivered
    end

    test "transitions batch to partially_delivered when some requests succeed and some fail", %{
      server: server
    } do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create two requests
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # First request succeeds
      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request1)
        |> Ash.run_action()

      # Second request fails
      expect_json_response(server, :post, "/webhook", %{error: "Failed"}, 500)

      {:ok, _} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request2)
        |> Ash.run_action()

      # Trigger batch completion check (normally done by AshOban)
      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered
    end

    test "delivery_attempt_count reflects number of attempts", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, :delivery_attempt_count)
      assert request_after.delivery_attempt_count == 1
    end

    test "records delivery attempt with correct type", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])

      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.delivery_config["type"] == "webhook"
    end

    test "handles webhook response with JSON body in error message", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Return JSON error response
      error_response = %{"error" => "Rate limited", "retry_after" => 60}
      expect_json_response(server, :post, "/webhook", error_response, 429)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      # Error message should contain JSON-encoded response
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
      assert attempt.error_msg =~ "Rate limited"
    end

    test "handles webhook response with plain text body in error message", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Return plain text error response
      TestServer.add(server, "/webhook",
        via: :post,
        to: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(400, "Bad Request: Invalid payload")
        end
      )

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      # Error message should contain the text response
      assert attempt.error_msg
      assert attempt.error_msg =~ "Bad Request"
    end

    test "handles webhook response with non-JSON map body", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Return JSON error response (Req will decode it to a map)
      expect_json_response(server, :post, "/webhook", %{"error" => "Invalid"}, 400)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      # Error message should contain error details
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
    end

    test "handles webhook timeout error", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Use invalid URL to cause connection timeout
      # Use a non-routable IP that will timeout
      request =
        request
        |> Ecto.Changeset.change(
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "http://192.0.2.1:8080/webhook"
          }
        )
        |> Batcher.Repo.update!()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome != :success
      assert attempt.error_msg
    end

    test "handles 3xx redirect responses as errors", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :delivering)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      # Return 3xx redirect (not 2xx)
      expect_json_response(server, :post, "/webhook", %{redirect: true}, 301)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.outcome != :success
      assert request_after.state == :delivery_failed
    end

    test "does not transition batch if not in ready_to_deliver state", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      # Batch already in delivering state (not ready_to_deliver)
      # Create a batch with multiple requests so it doesn't transition to a terminal state
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create two requests - one to deliver, one to keep batch from completing
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      _request2 =
        seeded_request(
          batch_id: batch.id,
          state: :pending,
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => webhook_url
          },
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, _request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request1)
        |> Ash.run_action()

      # Batch should remain in delivering state (start_delivering only runs if state is ready_to_deliver)
      # and won't transition to a terminal state because request2 is still pending
      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :delivering
    end
  end

  describe "oban configuration" do
    test "deliver trigger is configured with max_attempts of 1 (no retries)" do
      # Verify the Oban trigger configuration for the deliver action
      # This ensures webhook delivery only attempts once and doesn't retry on failure
      triggers = Batching.Request |> AshOban.Info.oban_triggers()

      deliver_trigger = Enum.find(triggers, fn trigger -> trigger.action == :deliver end)

      assert deliver_trigger != nil, "Expected :deliver trigger to exist"
      assert deliver_trigger.max_attempts == 1, "Expected max_attempts to be 1 (no retries)"
    end
  end
end
