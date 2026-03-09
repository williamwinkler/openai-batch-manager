defmodule Batcher.Batching.Actions.DeliverWebhookStateTransitionsTest do
  use Batcher.DataCase, async: false
  use AMQP

  alias Batcher.Batching
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
end
