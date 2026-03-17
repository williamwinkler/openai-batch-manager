defmodule Batcher.Batching.Actions.DeliverLifecycleTest do
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

  defp run_deliver(request) do
    Batching.Request
    |> Ash.ActionInput.for_action(:deliver, %{})
    |> Map.put(:subject, request)
    |> Ash.run_action()
  end

  describe "one-shot delivery behavior" do
    test "fails webhook delivery in one attempt", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"

      batch = seeded_batch(state: :delivering) |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => webhook_url},
          response_payload: %{"output" => "test response"}
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{error: "fail once"}, 500)
      assert {:ok, request_after} = run_deliver(request)

      request_after = Ash.load!(request_after, [:delivery_attempt_count, :delivery_attempts])
      assert request_after.state == :delivery_failed
      assert request_after.delivery_attempt_count == 1
      assert length(request_after.delivery_attempts) == 1
    end

    test "manual retry_delivery creates a fresh one-shot attempt", %{server: server} do
      webhook_url = TestServer.url(server) <> "/webhook"

      batch = seeded_batch(state: :delivering) |> generate()

      request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => webhook_url},
          response_payload: %{"output" => "test response"}
        )
        |> generate()

      expect_json_response(server, :post, "/webhook", %{error: "fail first"}, 500)
      assert {:ok, first_after} = run_deliver(request)
      assert first_after.state == :delivery_failed

      batch
      |> Ash.Changeset.for_update(:mark_partially_delivered)
      |> Ash.update!()

      retried =
        first_after
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()

      assert retried.state == :openai_processed

      expect_json_response(server, :post, "/webhook", %{received: true}, 200)
      assert {:ok, second_after} = run_deliver(request)

      second_after = Ash.load!(second_after, [:delivery_attempt_count, :delivery_attempts])
      assert second_after.state == :delivered
      assert second_after.delivery_attempt_count == 2
      assert length(second_after.delivery_attempts) == 2
    end
  end

  describe "oban configuration" do
    test "deliver trigger is configured with bounded retries" do
      triggers = Batching.Request |> AshOban.Info.oban_triggers()

      deliver_trigger = Enum.find(triggers, fn trigger -> trigger.action == :deliver end)

      assert deliver_trigger != nil, "Expected :deliver trigger to exist"
      assert deliver_trigger.max_attempts == 3, "Expected max_attempts to be 3"
    end
  end
end
