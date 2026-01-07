defmodule Batcher.Batching.Actions.ExpireStaleBuildingBatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  import Batcher.Generator

  describe "expire_stale_building_batch action" do
    test "deletes empty batch that has been building for over 1 hour" do
      # Create an empty batch (no requests)
      batch = generate(batch())

      # Manually set created_at to be over 1 hour ago
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3601, :second)

      batch =
        batch
        |> Ecto.Changeset.change(created_at: one_hour_ago)
        |> Batcher.Repo.update!()

      # Verify batch exists and is empty
      batch = Batching.get_batch_by_id!(batch.id, load: [:request_count])
      assert batch.state == :building
      assert batch.request_count == 0

      # Run the expire action
      result =
        Batching.Batch
        |> Ash.ActionInput.for_action(:expire_stale_building_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should return ok with nil (batch was deleted)
      assert {:ok, nil} = result

      # Verify batch was deleted
      assert {:error, %Ash.Error.Invalid{}} = Batching.get_batch_by_id(batch.id)
    end

    test "transitions non-empty batch to uploading after 1 hour" do
      # Create a batch with requests
      batch = generate(batch())
      generate(request(batch_id: batch.id, url: batch.url, model: batch.model))

      # Manually set created_at to be over 1 hour ago
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3601, :second)

      batch =
        batch
        |> Ecto.Changeset.change(created_at: one_hour_ago)
        |> Batcher.Repo.update!()

      # Verify batch exists and has requests
      batch = Batching.get_batch_by_id!(batch.id, load: [:request_count])
      assert batch.state == :building
      assert batch.request_count == 1

      # Run the expire action
      {:ok, updated_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:expire_stale_building_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should transition to uploading state
      assert updated_batch.state == :uploading
    end

    test "handles batch with multiple requests correctly" do
      # Create a batch with multiple requests
      batch = generate(batch())

      generate_many(
        request(batch_id: batch.id, url: batch.url, model: batch.model),
        5
      )

      # Manually set created_at to be over 1 hour ago
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3601, :second)

      batch =
        batch
        |> Ecto.Changeset.change(created_at: one_hour_ago)
        |> Batcher.Repo.update!()

      # Verify batch has requests
      batch = Batching.get_batch_by_id!(batch.id, load: [:request_count])
      assert batch.request_count == 5

      # Run the expire action
      {:ok, updated_batch} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:expire_stale_building_batch, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should transition to uploading, not delete
      assert updated_batch.state == :uploading
    end
  end
end
