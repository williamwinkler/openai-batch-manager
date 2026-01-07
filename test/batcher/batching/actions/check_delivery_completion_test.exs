defmodule Batcher.Batching.Actions.CheckDeliveryCompletionTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  import Batcher.Generator

  describe "check_delivery_completion action" do
    test "transitions to done when all requests are in terminal states" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create requests in various terminal states
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :failed))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :done
    end

    test "stays in delivering when some requests are not in terminal states" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Mix of terminal and non-terminal states
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :openai_processed))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivering
    end

    test "does nothing when batch is not in delivering state" do
      batch =
        seeded_batch(state: :ready_to_deliver)
        |> generate()

      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :openai_processed))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # Should remain in ready_to_deliver state
      assert batch_after.state == :ready_to_deliver
    end

    test "handles all terminal states correctly" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # Create requests in all possible terminal states
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :failed))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivery_failed))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :expired))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :cancelled))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :done
    end

    test "creates transition record when transitioning to done" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      batch_after = Ash.load!(batch_after, [:transitions])

      assert batch_after.state == :done

      # Find the transition to done
      done_transition = Enum.find(batch_after.transitions, &(&1.to == :done))
      assert done_transition != nil
      assert done_transition.from == :delivering
    end

    test "handles batch with no requests" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      # No requests created

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      # With no requests, requests_terminal_count should be true (0 non-terminal = all terminal)
      assert batch_after.state == :done
    end

    test "stays in delivering when requests are in delivering state" do
      batch =
        seeded_batch(state: :delivering)
        |> generate()

      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered))
      generate(seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivering))

      {:ok, batch_after} =
        Batching.Batch
        |> Ash.ActionInput.for_action(:check_delivery_completion, %{})
        |> Map.put(:subject, batch)
        |> Ash.run_action()

      assert batch_after.state == :delivering
    end
  end
end
