defmodule Batcher.Batching.Actions.RedeliverTest do
  use Batcher.DataCase, async: true
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

      assert batch_after.state == :partially_delivered

      # Failed requests should be reset to openai_processed
      r1 = Batching.get_request_by_id!(failed_request1.id)
      r2 = Batching.get_request_by_id!(failed_request2.id)
      assert r1.state == :openai_processed
      assert r2.state == :openai_processed

      # Delivered request is replayable and should also be requeued
      delivered = Batching.get_request_by_id!(delivered_request.id)
      assert delivered.state == :openai_processed
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

      assert batch_after.state == :delivery_failed

      r = Batching.get_request_by_id!(failed_request.id)
      assert r.state == :openai_processed
    end

    test "returns batch unchanged when no deliverable requests exist" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      # Delivered request without payload is not deliverable
      _delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: nil
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      # Batch should remain in partially_delivered since no requests needed redelivery
      assert batch_after.state == :partially_delivered
    end

    test "returns batch unchanged when requests are non-deliverable (missing response payload)" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      _non_deliverable_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: nil
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered
    end

    test "resumes queued openai_processed requests even when no failed requests exist" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      _delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "already delivered"}
        )
        |> generate()

      queued_request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "queued"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered
      assert_enqueued(worker: Batching.Request.AshOban.Worker.Deliver)

      # Queued request remains openai_processed until worker starts it.
      assert Batching.get_request_by_id!(queued_request.id).state == :openai_processed
    end

    test "allows redelivery from building state when deliverable requests exist" do
      batch =
        seeded_batch(state: :building)
        |> generate()

      deliverable_request =
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

      assert batch_after.state == :building
      assert Batching.get_request_by_id!(deliverable_request.id).state == :openai_processed
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

    test "allows redelivery from delivered state when deliverable requests exist" do
      batch =
        seeded_batch(state: :delivered)
        |> generate()

      deliverable_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :delivered
      assert Batching.get_request_by_id!(deliverable_request.id).state == :openai_processed
    end

    test "allows redelivery from ready_to_deliver state when deliverable requests exist" do
      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      deliverable_request =
        seeded_request(
          batch_id: batch.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :ready_to_deliver
      assert Batching.get_request_by_id!(deliverable_request.id).state == :openai_processed
    end

    test "redelivers delivered requests for manual replay" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "already delivered"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered
      assert Batching.get_request_by_id!(delivered_request.id).state == :openai_processed
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

    test "redeliver_failed only requeues failed requests" do
      batch =
        seeded_batch(state: :partially_delivered)
        |> generate()

      failed_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivery_failed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "failed"}
        )
        |> generate()

      delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "delivered"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver_failed, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :partially_delivered
      assert Batching.get_request_by_id!(failed_request.id).state == :openai_processed
      assert Batching.get_request_by_id!(delivered_request.id).state == :delivered
    end

    test "redeliver_failed returns batch unchanged when no failed deliverable requests exist" do
      batch =
        seeded_batch(state: :delivery_failed)
        |> generate()

      _delivered_request =
        seeded_request(
          batch_id: batch.id,
          state: :delivered,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "delivered"}
        )
        |> generate()

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:redeliver_failed, %{id: batch.id})
        |> Ash.run_action()

      assert batch_after.state == :delivery_failed
    end
  end
end
