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

      request_after =
        Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts, :batch])

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

    test "saves response body in error_msg on delivery_attempt (not request) on 4xx error", %{server: server} do
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

      assert request_after.state == :delivery_failed
      assert request_after.delivery_attempt_count == 1
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Verify delivery attempt was recorded with failure and contains error details
      assert length(request_after.delivery_attempts) == 1
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
      assert attempt.error_msg =~ "INVALID"
    end

    test "saves response body in error_msg on delivery_attempt (not request) on 5xx error", %{server: server} do
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

      assert request_after.state == :delivery_failed
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Verify delivery attempt was recorded with failure and contains error details
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg
      assert attempt.error_msg =~ "error"
    end

    test "handles connection refused error" do
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

      assert request_after.state == :delivery_failed
      # error_msg should NOT be set on request - delivery failures are not request errors
      assert request_after.error_msg == nil

      # Error details are stored on delivery_attempt
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg != nil
    end

    test "raises error for RabbitMQ delivery type" do
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

    test "raises error when webhook_url is missing" do
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

    test "transitions batch to done when all requests are delivered or delivery_failed", %{server: server} do
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

    test "handles webhook response with JSON body in error message", %{server: server} do
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

      # Use invalid URL to cause connection timeout
      # Use a non-routable IP that will timeout
      request =
        request
        |> Ecto.Changeset.change(webhook_url: "http://192.0.2.1:8080/webhook")
        |> Batcher.Repo.update!()

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert attempt.error_msg
    end

    test "handles 3xx redirect responses as errors", %{server: server} do
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

      # Return 3xx redirect (not 2xx)
      expect_json_response(server, :post, "/webhook", %{redirect: true}, 301)

      {:ok, request_after} =
        Batching.Request
        |> Ash.ActionInput.for_action(:deliver, %{})
        |> Map.put(:subject, request)
        |> Ash.run_action()

      request_after = Ash.load!(request_after, [:delivery_attempts])
      attempt = List.first(request_after.delivery_attempts)
      assert attempt.success == false
      assert request_after.state == :delivery_failed
    end

    test "does not transition batch if not in ready_to_deliver state", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      # Batch already in delivering state (not ready_to_deliver)
      # Create a batch with multiple requests so it doesn't transition to :done
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create two requests - one to deliver, one to keep batch from completing
      request1 =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_type: :webhook,
          webhook_url: webhook_url,
          response_payload: response_payload
        )
        |> generate()

      _request2 =
        seeded_request(
          batch_id: batch.id,
          state: :pending,
          delivery_type: :webhook,
          webhook_url: webhook_url,
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
      # and won't transition to :done because request2 is still pending
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
