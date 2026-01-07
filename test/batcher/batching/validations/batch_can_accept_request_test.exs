defmodule Batcher.Batching.Validations.BatchCanAcceptRequestTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  alias Batcher.Batching.Validations.BatchCanAcceptRequest

  import Batcher.Generator

  describe "validate/3" do
    test "returns :ok when batch is in building state and has capacity" do
      batch = generate(batch())

      # Create a minimal changeset with just batch_id to test validation in isolation
      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert result == :ok
    end

    test "returns error when batch is not in building state" do
      batch = generate(seeded_batch(state: :uploading))

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert {:error, field: :batch_id, message: message} = result
      assert String.contains?(message, "not in building state")
    end

    test "returns error when batch is full" do
      batch = generate(batch())

      # Create requests up to the test limit (5 requests)
      generate_many(request(batch_id: batch.id), 5)

      # Reload batch to get updated request_count
      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:request_count, :size_bytes])

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert {:error, field: :batch_id, message: message} = result
      assert String.contains?(message, "full")
      assert String.contains?(message, "max 5 requests")
    end

    test "returns error when batch size exceeds limit" do
      batch = generate(batch())

      # Create requests with large payloads to exceed 1MB limit
      # Each request payload is ~350KB, so 3 requests = ~1.05MB > 1MB limit
      # This stays under the 5 request count limit
      large_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # Create 3 requests with large payloads (total ~1.05MB > 1MB limit)
      for i <- 1..3 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "large_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(large_payload_base, :custom_id, "large_#{i}"),
            delivery: %{
              type: "webhook",
              webhook_url: "https://example.com/webhook"
            }
          })
      end

      # Reload batch to get updated size_bytes
      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:request_count, :size_bytes])

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert {:error, field: :batch_id, message: message} = result
      assert String.contains?(message, "exceeds")
      assert String.contains?(message, "1MB")
    end

    test "returns error when batch_id doesn't exist" do
      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, 999_999)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert {:error, field: :batch_id, message: message} = result
      assert String.contains?(message, "batch not found")
    end

    test "handles nil batch_id gracefully" do
      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, nil)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert {:error, field: :batch_id, message: _message} = result
    end

    test "validates all three conditions in order" do
      # Test that if batch is not in building state, it fails before checking capacity
      batch = generate(seeded_batch(state: :uploading))

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      # Should fail on state check, not capacity check
      assert {:error, field: :batch_id, message: message} = result
      assert String.contains?(message, "not in building state")
      refute String.contains?(message, "full")
      refute String.contains?(message, "exceeds")
    end
  end
end
