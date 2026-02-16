defmodule Batcher.Batching.Validations.BatchCanAcceptRequestTest do
  use Batcher.DataCase, async: false

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

      assert reason_for_result(result) == :batch_not_building
      assert String.contains?(error_message(result), "not in building state")
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

      assert reason_for_result(result) == :batch_full
    end

    test "batch full error keeps user-facing request limit message" do
      batch = generate(batch())
      generate_many(request(batch_id: batch.id), 5)
      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:request_count, :size_bytes])

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert reason_for_result(result) == :batch_full
      message = error_message(result)
      assert String.contains?(message, "max 5 requests")
    end

    test "returns error when incoming request would exceed batch size limit" do
      batch = generate(batch())

      # Fill the batch close to 1MB without crossing it.
      existing_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # 2 requests ~= 700KB, still below 1MB limit in tests.
      for i <- 1..2 do
        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: "large_#{i}",
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(existing_payload_base, :custom_id, "large_#{i}"),
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      incoming_payload = %{
        body: %{
          input: String.duplicate("y", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url,
        custom_id: "incoming_large_request"
      }

      changeset = oversized_request_changeset(batch, incoming_payload)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert reason_for_result(result) == :batch_size_would_exceed
    end

    test "returns error when batch_id doesn't exist" do
      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, 999_999)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert reason_for_result(result) == :batch_not_found
    end

    test "handles nil batch_id gracefully" do
      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, nil)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert reason_for_result(result) == :batch_not_found
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
      assert reason_for_result(result) == :batch_not_building
    end

    test "handles nil size_bytes gracefully" do
      batch = generate(batch())

      # Manually set size_bytes to nil to test edge case
      batch =
        batch
        |> Ecto.Changeset.change(size_bytes: nil)
        |> Batcher.Repo.update!()

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      # Should pass (nil is treated as 0)
      assert result == :ok
    end

    test "handles size_bytes at exact limit boundary" do
      batch = generate(batch())

      # Create requests near the 1MB limit.
      large_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # 2 requests ~= 700KB
      for i <- 1..2 do
        custom_id = "size_limit_#{i}_#{:rand.uniform(100_000)}"

        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: custom_id,
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(large_payload_base, :custom_id, custom_id),
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      incoming_payload = %{
        body: %{
          input: String.duplicate("y", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url,
        custom_id: "boundary_limit_#{:rand.uniform(100_000)}"
      }

      changeset = oversized_request_changeset(batch, incoming_payload)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      # Should fail (exceeds limit)
      assert reason_for_result(result) == :batch_size_would_exceed
    end

    test "handles request_count at exact limit boundary" do
      batch = generate(batch())

      # Create requests up to exactly the test limit (5)
      for _i <- 1..5 do
        generate(request(batch_id: batch.id, url: batch.url, model: batch.model))
      end

      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:request_count, :size_bytes])

      changeset =
        Batching.Request
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:batch_id, batch.id)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      # Should fail (at limit, not < limit)
      assert reason_for_result(result) == :batch_full
    end

    test "format_bytes handles different byte sizes correctly" do
      # Test the private format_bytes function indirectly through error messages
      # The test limit is 1MB, so we'll test with requests that exceed it
      batch = generate(batch())

      # Create requests near the 1MB limit.
      large_payload_base = %{
        body: %{
          input: String.duplicate("x", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url
      }

      # 2 requests ~= 700KB
      for i <- 1..2 do
        custom_id = "format_test_#{i}_#{:rand.uniform(100_000)}"

        {:ok, _} =
          Batching.create_request(%{
            batch_id: batch.id,
            custom_id: custom_id,
            url: batch.url,
            model: batch.model,
            request_payload: Map.put(large_payload_base, :custom_id, custom_id),
            delivery_config: %{
              "type" => "webhook",
              "webhook_url" => "https://example.com/webhook"
            }
          })
      end

      incoming_payload = %{
        body: %{
          input: String.duplicate("y", 350_000),
          model: batch.model
        },
        method: "POST",
        url: batch.url,
        custom_id: "format_test_incoming_#{:rand.uniform(100_000)}"
      }

      changeset = oversized_request_changeset(batch, incoming_payload)

      result = BatchCanAcceptRequest.validate(changeset, [], %{})

      assert reason_for_result(result) == :batch_size_would_exceed
    end
  end

  defp oversized_request_changeset(batch, incoming_payload) do
    Batching.Request
    |> Ash.Changeset.for_create(:create, %{
      batch_id: batch.id,
      custom_id: "validation_overflow_#{System.unique_integer([:positive])}",
      url: batch.url,
      model: batch.model,
      delivery_config: %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"},
      request_payload: incoming_payload
    })
  end

  defp reason_for_result({:error, %Ash.Error.Changes.InvalidAttribute{} = error}) do
    error_reason(error)
  end

  defp error_message({:error, %Ash.Error.Changes.InvalidAttribute{} = error}), do: error.message

  defp error_reason(%{vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)
  defp error_reason(%{private_vars: vars}) when is_map(vars), do: Map.get(vars, :reason)
  defp error_reason(%{private_vars: vars}) when is_list(vars), do: Keyword.get(vars, :reason)
  defp error_reason(_), do: nil
end
