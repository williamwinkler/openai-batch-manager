defmodule Batcher.Batching.Calculations.BatchDeliveryStatsTest do
  use Batcher.DataCase, async: true

  import Batcher.Generator

  describe "BatchDeliveryStats calculation" do
    test "returns correct counts when batch has only delivered requests" do
      batch = generate(seeded_batch())

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered)
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered)
      )

      batch = Ash.load!(batch, :delivery_stats)

      assert batch.delivery_stats == %{delivered: 2, delivering: 0, failed: 0, queued: 0}
    end

    test "returns correct counts when batch has only failed requests" do
      batch = generate(seeded_batch())

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :failed)
      )

      generate(
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :delivery_failed
        )
      )

      batch = Ash.load!(batch, :delivery_stats)

      assert batch.delivery_stats == %{delivered: 0, delivering: 0, failed: 1, queued: 0}
    end

    test "returns correct counts when batch has mixed delivered and failed requests" do
      batch = generate(seeded_batch())

      # Delivered requests
      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered)
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered)
      )

      # Failed requests (various failure states)
      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :failed)
      )

      generate(
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :delivery_failed
        )
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :expired)
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :cancelled)
      )

      batch = Ash.load!(batch, :delivery_stats)

      assert batch.delivery_stats == %{delivered: 2, delivering: 0, failed: 1, queued: 0}
    end

    test "returns zeros when batch has no requests" do
      batch = generate(seeded_batch())

      batch = Ash.load!(batch, :delivery_stats)

      assert batch.delivery_stats == %{delivered: 0, delivering: 0, failed: 0, queued: 0}
    end

    test "does not count non-terminal requests" do
      batch = generate(seeded_batch())

      # Delivered (terminal)
      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivered)
      )

      # Non-terminal states - should not be counted
      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :pending)
      )

      generate(
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :openai_processing
        )
      )

      generate(
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :openai_processed
        )
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :delivering)
      )

      batch = Ash.load!(batch, :delivery_stats)

      # Only counts :delivered (1), :delivering (1) and failed states (0)
      # Non-terminal states (pending, openai_processing, openai_processed) are not counted
      assert batch.delivery_stats == %{delivered: 1, delivering: 1, failed: 0, queued: 1}
    end

    test "counts only delivery_failed as failed outcomes" do
      batch = generate(seeded_batch())

      # Each type of failure state
      generate(
        seeded_request(
          batch_id: batch.id,
          url: batch.url,
          model: batch.model,
          state: :delivery_failed
        )
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :failed)
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :expired)
      )

      generate(
        seeded_request(batch_id: batch.id, url: batch.url, model: batch.model, state: :cancelled)
      )

      batch = Ash.load!(batch, :delivery_stats)

      assert batch.delivery_stats == %{delivered: 0, delivering: 0, failed: 1, queued: 0}
    end
  end
end
