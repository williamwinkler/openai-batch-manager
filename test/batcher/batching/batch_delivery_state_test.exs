defmodule Batcher.Batching.BatchDeliveryStateTest do
  use Batcher.DataCase, async: false
  use Oban.Testing, repo: Batcher.Repo

  alias Batcher.Batching

  import Batcher.Generator
  import Batcher.TestServer

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "Batcher.Batching.Batch.start_delivering" do
    test "transitions batch from ready_to_deliver to delivering" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_delivering)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivering

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :ready_to_deliver
      assert latest_transition.to == :delivering
      assert latest_transition.transitioned_at
    end

    test "enqueues delivery jobs for openai_processed requests in the batch" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      _request1 =
        seeded_request(
          batch_id: batch_before.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response-1"}
        )
        |> generate()

      _request2 =
        seeded_request(
          batch_id: batch_before.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response-2"}
        )
        |> generate()

      _batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_delivering)
        |> Ash.update!()

      assert_enqueued(worker: Batching.Request.AshOban.Worker.Deliver)
    end

    test "enqueues all openai_processed requests across multiple chunks" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      generate_many(
        seeded_request(
          batch_id: batch_before.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "response"}
        ),
        7
      )

      _batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_delivering)
        |> Ash.update!()

      queued_count =
        all_enqueued(worker: Batching.Request.AshOban.Worker.Deliver)
        |> length()

      assert queued_count == 7
    end

    test "enqueues delivery jobs only for openai_processed requests" do
      batch_before =
        seeded_batch(
          state: :ready_to_deliver,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      generate(
        seeded_request(
          batch_id: batch_before.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "queued-1"}
        )
      )

      generate(
        seeded_request(
          batch_id: batch_before.id,
          state: :openai_processed,
          delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
          response_payload: %{"output" => "queued-2"}
        )
      )

      generate(seeded_request(batch_id: batch_before.id, state: :pending))
      generate(seeded_request(batch_id: batch_before.id, state: :delivering))
      generate(seeded_request(batch_id: batch_before.id, state: :delivery_failed))

      _batch_after =
        batch_before
        |> Ash.Changeset.for_update(:start_delivering)
        |> Ash.update!()

      queued_count =
        all_enqueued(worker: Batching.Request.AshOban.Worker.Deliver)
        |> length()

      assert queued_count == 2
    end
  end

  describe "Batcher.Batching.Batch.mark_delivered" do
    test "transitions batch from delivering to delivered" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_delivered)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivered

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :delivered
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.mark_partially_delivered" do
    test "transitions batch from delivering to partially_delivered" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_partially_delivered)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :partially_delivered

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :partially_delivered
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.mark_delivery_failed" do
    test "transitions batch from delivering to delivery_failed" do
      batch_before =
        seeded_batch(
          state: :delivering,
          openai_output_file_id: "file-output-123"
        )
        |> generate()

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:mark_delivery_failed)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :delivery_failed

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :delivering
      assert latest_transition.to == :delivery_failed
      assert latest_transition.transitioned_at
    end
  end

  describe "Batcher.Batching.Batch.cancel" do
    test "transitions batch to cancelled state", %{server: server} do
      openai_batch_id = "batch_123"

      batch_before =
        seeded_batch(
          state: :openai_processing,
          openai_batch_id: openai_batch_id
        )
        |> generate()

      # Mock successful cancel response
      cancel_response = %{
        "id" => openai_batch_id,
        "status" => "cancelling",
        "object" => "batch"
      }

      expect_json_response(
        server,
        :post,
        "/v1/batches/#{openai_batch_id}/cancel",
        cancel_response,
        200
      )

      batch_after =
        batch_before
        |> Ash.Changeset.for_update(:cancel)
        |> Ash.update!(load: [:transitions])

      assert batch_after.state == :cancelled

      # Verify transition record
      latest_transition = List.last(batch_after.transitions)
      assert latest_transition.from == :openai_processing
      assert latest_transition.to == :cancelled
      assert latest_transition.transitioned_at
    end

    test "can cancel batch from different states", %{server: server} do
      states = [:building, :uploading, :uploaded, :openai_processing]

      for state <- states do
        openai_batch_id = if state == :openai_processing, do: "batch_#{state}", else: nil

        batch_before =
          seeded_batch(
            state: state,
            openai_batch_id: openai_batch_id
          )
          |> generate()

        # Only mock API call for openai_processing state
        if state == :openai_processing do
          cancel_response = %{
            "id" => openai_batch_id,
            "status" => "cancelling",
            "object" => "batch"
          }

          expect_json_response(
            server,
            :post,
            "/v1/batches/#{openai_batch_id}/cancel",
            cancel_response,
            200
          )
        end

        batch_after =
          batch_before
          |> Ash.Changeset.for_update(:cancel)
          |> Ash.update!(load: [:transitions])

        assert batch_after.state == :cancelled

        latest_transition = List.last(batch_after.transitions)
        assert latest_transition.from == state
        assert latest_transition.to == :cancelled
      end
    end
  end
end
