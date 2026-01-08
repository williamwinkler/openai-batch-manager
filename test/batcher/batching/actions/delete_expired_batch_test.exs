defmodule Batcher.Batching.Actions.DeleteExpiredBatchTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Batching.RequestDeliveryAttempt
  alias Batcher.Batching.BatchTransition

  import Batcher.Generator

  describe "delete_expired_batch action" do
    test "deletes expired batch" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      batch =
        seeded_batch(
          state: :done,
          expires_at: expires_at
        )
        |> generate()

      # Verify batch exists
      assert {:ok, _} = Batching.get_batch_by_id(batch.id)

      # Run the delete action
      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:delete_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should return ok with nil (batch was deleted)
      assert {:ok, nil} = result

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "works when invoked via AshOban (primary_key in params)" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      batch =
        seeded_batch(
          state: :done,
          expires_at: expires_at
        )
        |> generate()

      # Invoke the action the way AshOban does - by setting params directly
      {:ok, nil} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:delete_expired_batch, %{})
        |> Map.put(:params, %{"primary_key" => %{"id" => batch.id}})
        |> Ash.run_action()

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "cascade deletes requests, delivery attempts, and batch transitions" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      # Create a batch
      batch = generate(batch())

      # Create requests in the batch
      request1 = generate(request(batch_id: batch.id, url: batch.url, model: batch.model))
      request2 = generate(request(batch_id: batch.id, url: batch.url, model: batch.model))

      # Create delivery attempts for the requests
      {:ok, _attempt1} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request1.id,
          type: :webhook,
          success: true
        })

      {:ok, _attempt2} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request1.id,
          type: :webhook,
          success: false,
          error_msg: "Failed"
        })

      {:ok, _attempt3} =
        Ash.create(RequestDeliveryAttempt, %{
          request_id: request2.id,
          type: :webhook,
          success: true
        })

      # Create batch transitions by changing state (transitions are created automatically)
      # Start upload to create a transition
      {:ok, batch} = Batching.start_batch_upload(batch)

      # Set expires_at after state transitions (truncate to seconds for database)
      batch =
        batch
        |> Ecto.Changeset.change(expires_at: DateTime.truncate(expires_at, :second))
        |> Batcher.Repo.update!()

      # Reload batch with all relationships
      batch = Batching.get_batch_by_id!(batch.id, load: [:requests, :transitions])
      request1 = Ash.load!(request1, [:delivery_attempts])
      request2 = Ash.load!(request2, [:delivery_attempts])

      # Verify data exists before deletion
      assert length(batch.requests) == 2
      assert length(batch.transitions) > 0
      assert length(request1.delivery_attempts) == 2
      assert length(request2.delivery_attempts) == 1

      # Get transition IDs before deletion
      transition_ids = Enum.map(batch.transitions, & &1.id)

      attempt_ids =
        Enum.map(request1.delivery_attempts, & &1.id) ++
          Enum.map(request2.delivery_attempts, & &1.id)

      # Delete the batch
      {:ok, nil} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:delete_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)

      # Verify requests were cascade deleted
      require Ash.Query

      request_ids = [request1.id, request2.id]

      assert [] =
               Batching.Request
               |> Ash.Query.filter(id in ^request_ids)
               |> Ash.read!()

      # Verify delivery attempts were cascade deleted
      assert [] =
               RequestDeliveryAttempt
               |> Ash.Query.filter(id in ^attempt_ids)
               |> Ash.read!()

      # Verify batch transitions were cascade deleted
      assert [] =
               BatchTransition
               |> Ash.Query.filter(id in ^transition_ids)
               |> Ash.read!()
    end

    test "handles deletion error gracefully" do
      # Create a batch that might have constraints preventing deletion
      # (though cascade delete should handle this)
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      batch =
        seeded_batch(
          state: :done,
          expires_at: expires_at
        )
        |> generate()

      # Try to delete - should succeed with cascade
      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:delete_expired_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should succeed (cascade delete handles related records)
      assert {:ok, nil} = result
    end

  end
end
