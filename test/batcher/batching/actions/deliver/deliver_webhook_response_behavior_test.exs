defmodule Batcher.Batching.Actions.DeliverWebhookResponseBehaviorTest do
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
    test "delivers even when batch is not in delivering state", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"
      response_payload = %{"output" => "test response"}

      batch =
        seeded_batch(state: :downloading)
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

      request_after = Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts])

      assert request_after.state == :delivered
      assert request_after.delivery_attempt_count == 1
      assert length(request_after.delivery_attempts) == 1
    end

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
  end
end
