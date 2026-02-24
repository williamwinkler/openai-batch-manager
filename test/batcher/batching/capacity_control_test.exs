defmodule Batcher.Batching.CapacityControlTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching.CapacityControl

  import Batcher.Generator

  describe "decision/1" do
    test "admits when needed tokens fit remaining headroom" do
      model = "gpt-4o-mini"

      _reserved =
        generate(
          seeded_batch(
            model: model,
            state: :openai_processing,
            estimated_request_input_tokens_total: 1_200_000
          )
        )

      candidate =
        generate(
          seeded_batch(
            model: model,
            state: :waiting_for_capacity,
            estimated_request_input_tokens_total: 800_000
          )
        )

      assert {:admit, %{headroom: 800_000, needed: 800_000}} = CapacityControl.decision(candidate)
    end

    test "waits for capacity when needed tokens exceed headroom" do
      model = "gpt-4o-mini"

      _reserved =
        generate(
          seeded_batch(
            model: model,
            state: :openai_processing,
            estimated_request_input_tokens_total: 1_200_000
          )
        )

      candidate =
        generate(
          seeded_batch(
            model: model,
            state: :waiting_for_capacity,
            estimated_request_input_tokens_total: 800_001
          )
        )

      assert {:wait_capacity_blocked, %{headroom: 800_000, needed: 800_001}} =
               CapacityControl.decision(candidate)
    end

    test "does not emit fairness-blocked outcomes" do
      model = "gpt-4o-mini"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      _older_waiting =
        generate(
          seeded_batch(
            model: model,
            state: :waiting_for_capacity,
            waiting_for_capacity_since_at: DateTime.add(now, -120, :second),
            estimated_request_input_tokens_total: 1_700_000
          )
        )

      candidate =
        generate(
          seeded_batch(
            model: model,
            state: :waiting_for_capacity,
            waiting_for_capacity_since_at: DateTime.add(now, -60, :second),
            estimated_request_input_tokens_total: 100_000
          )
        )

      assert {:admit, _context} = CapacityControl.decision(candidate)
    end
  end

  describe "fits_headroom?/3" do
    test "returns true only when batch estimate is <= remaining headroom" do
      batch = generate(seeded_batch(estimated_request_input_tokens_total: 200_000))

      assert CapacityControl.fits_headroom?(batch, 1_700_000, 2_000_000)
      refute CapacityControl.fits_headroom?(batch, 1_900_001, 2_000_000)
    end
  end
end
