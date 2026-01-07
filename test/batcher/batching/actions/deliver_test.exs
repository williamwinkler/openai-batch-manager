defmodule Batcher.Batching.Actions.DeliverTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    {:ok, server: server}
  end

  describe "deliver action" do
    test "successfully delivers webhook with 200 status", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response", "status" => "success"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      request_after = Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts, :batch])

      assert request_after.state == :delivered
      assert request_after.delivery_attempt_count == 1

      # Verify delivery attempt was recorded
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == true
      assert attempt.type == :webhook
      assert attempt.error_msg == nil

      # Verify batch transitioned to delivering
      assert request_after.batch.state == :delivering
    end

    test "successfully delivers webhook with 201 status", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

    test "saves response body in error_msg on 4xx error", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      assert request_after.state == :failed
      assert request_after.delivery_attempt_count == 1
      assert request_after.error_msg
      # Verify error_msg contains the response body as JSON
      assert request_after.error_msg =~ "error"
      assert request_after.error_msg =~ "INVALID"

      # Verify delivery attempt was recorded with failure
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
    end

    test "saves response body in error_msg on 5xx error", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      assert request_after.state == :failed
      assert request_after.error_msg
      assert request_after.error_msg =~ "error"

      # Verify delivery attempt was recorded with failure
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg
    end

    test "handles connection refused error", %{server: _server} do
      # Use an invalid URL that will cause connection refused
      # Use a non-routable IP address to ensure connection failure
      webhook_url = "http://192.0.2.1:8080/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      assert request_after.state == :failed
      assert request_after.error_msg
    end

    test "raises error for RabbitMQ delivery type", %{server: _server} do
      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :rabbitmq,
          rabbitmq_queue: "results_queue",
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

    test "raises error when webhook_url is missing", %{server: _server} do
      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: nil,
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
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
          response_payload: response_payload
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)

      {:ok, _request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      # Reload batch to check state
      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :delivering
    end

    test "transitions batch to done when all requests are delivered", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      # Create two requests
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      # Reload batch to check state
      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :done
    end

    test "transitions batch to done when all requests are delivered or failed", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      # Create two requests
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
          response_payload: response_payload
        )
        |> generate()

      request2 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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

      # Reload batch to check state
      batch_after = Batching.get_batch_by_id!(batch.id)
      assert batch_after.state == :done
    end

    test "delivery_attempt_count reflects number of attempts", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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
      assert attempt.type == :webhook
    end
  end
end
