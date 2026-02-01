defmodule Batcher.Batching.Actions.RedeliverTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator

  describe "redeliver action" do
    test "redelivers failed requests from a partially_delivered batch" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      # One delivered request, two failed requests
      delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "success"}
        )
        |> generate()

      failed_request1 =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response1"}
        )
        |> generate()

      failed_request2 =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response2"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      # Batch should transition to delivering
      assert batch_after.state == :delivering

      # Failed requests should be reset to openai_processed
      r1 = Batching.get_request_by_id!(failed_request1.id)
      r2 = Batching.get_request_by_id!(failed_request2.id)
      assert r1.state == :openai_processed
      assert r2.state == :openai_processed

      # Delivered request should remain delivered
      delivered = Batching.get_request_by_id!(delivered_request.id)
      assert delivered.state == :delivered
    end

    test "redelivers failed requests from a delivery_failed batch" do
      batch =
        seeded_batch(state: :delivery_failed)
        |> generate()

      failed_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :delivering

      r = Batching.get_request_by_id!(failed_request.id)
      assert r.state == :openai_processed
    end

    test "returns batch unchanged when no failed requests exist" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      # Only delivered requests, no failed ones
      _delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "success"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      # Batch should remain in partially_delivered since no requests needed redelivery
      assert batch_after.state == :partially_delivered
    end

    test "returns error when batch is in building state" do
      batch =
        seeded_batch(state: :building)
        |> generate()

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "returns error when batch is in delivering state" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "returns error when batch is in delivered state" do
      batch =
        seeded_batch(state: :delivered)
        |> generate()

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "returns error when batch is in ready_to_deliver state" do
      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "schedules delivery oban jobs for each failed request" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      _failed_request1 =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response1"}
        )
        |> generate()

      _failed_request2 =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response2"}
        )
        |> generate()

      {:ok, _batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      # retry_delivery triggers the :deliver oban job for each request
      assert_enqueued(worker: Batching.Request.AshOban.Worker.Deliver)
    end

    test "records batch state transition to delivering" do
      batch =
        seeded_batch(state: :delivery_failed)
        |> generate()

      _failed_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      redeliver_transition =
        Enum.find(batch_after.transitions, fn t ->
          t.to == :delivering and t.from in [:delivery_failed, :partially_delivered]
        end)

      assert redeliver_transition != nil
    end

    test "only redelivers requests belonging to the specified batch" do
      batch1 =
        seeded_batch(state: :partially_delivered)
        |> generate()

      batch2 =
        seeded_batch(state: :partially_delivered)
        |> generate()

      # Failed request in batch1
      failed_in_batch1 =
        seeded_request(
          batch_id: batch1.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      # Failed request in batch2
      failed_in_batch2 =
        seeded_request(
          batch_id: batch2.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      # Redeliver only batch1
      {:ok, _} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch1.id})
        |> Ash.run_action()

      # batch1's request should be reset
      r1 = Batching.get_request_by_id!(failed_in_batch1.id)
      assert r1.state == :openai_processed

      # batch2's request should remain failed
      r2 = Batching.get_request_by_id!(failed_in_batch2.id)
      assert r2.state == :delivery_failed
    end
  end
end
