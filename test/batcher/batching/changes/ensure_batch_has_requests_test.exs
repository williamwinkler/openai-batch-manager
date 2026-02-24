defmodule Batcher.Batching.Changes.EnsureBatchHasRequestsTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  import Batcher.Generator

  describe "EnsureBatchHasRequests change" do
    test "prevents start_upload action on empty batch" do
      # Create an empty batch
      batch = generate(batch())

      # Verify batch is empty
      batch = Batching.get_batch_by_id!(batch.id)
      assert batch.request_count == 0
      assert batch.state == :building

      # Attempt to start upload
      changeset = Ash.Changeset.for_update(batch, :start_upload)

      # Should add an error
      assert changeset.valid? == false

      assert Enum.any?(changeset.errors, fn error ->
               error.field == :id and
                 String.contains?(error.message, "Cannot upload empty batch")
             end)
    end

    test "allows start_upload action on batch with requests" do
      # Create a batch with a request
      batch = generate(batch())
      generate(request(batch_id: batch.id, url: batch.url, model: batch.model))

      # Verify batch has requests
      batch = Batching.get_batch_by_id!(batch.id)
      assert batch.request_count == 1
      assert batch.state == :building

      # Attempt to start upload
      changeset = Ash.Changeset.for_update(batch, :start_upload)

      # Should be valid (no error)
      assert changeset.valid? == true
    end

    test "allows start_upload action on batch with multiple requests" do
      # Create a batch with multiple requests
      batch = generate(batch())

      generate_many(
        request(batch_id: batch.id, url: batch.url, model: batch.model),
        10
      )

      # Verify batch has requests
      batch = Batching.get_batch_by_id!(batch.id)
      assert batch.request_count == 10

      # Attempt to start upload
      changeset = Ash.Changeset.for_update(batch, :start_upload)

      # Should be valid
      assert changeset.valid? == true
    end
  end
end
