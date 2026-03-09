defmodule Batcher.Batching.Actions.DeliverRabbitmqBehaviorTest do
  use Batcher.DataCase, async: false
  use AMQP

  alias Batcher.Batching
  alias Batcher.RabbitMQ.FakePublisher

  import Batcher.Generator

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
            "rabbitmq_queue" => "test_queue"
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
            "rabbitmq_queue" => "non_existent_queue"
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
            "rabbitmq_queue" => "test_queue"
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
            "rabbitmq_queue" => "test_queue"
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
            "rabbitmq_queue" => "success_queue"
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
            "rabbitmq_queue" => "fail_queue"
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
      assert attempt.outcome == :connection_error
      assert attempt.error_msg != nil
      assert attempt.error_msg =~ "RabbitMQ is not configured"
    end
  end
end
