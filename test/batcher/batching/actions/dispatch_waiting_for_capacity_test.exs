defmodule Batcher.Batching.Actions.DispatchWaitingForCapacityTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Batching.Actions.DispatchWaitingForCapacity
  import Batcher.TestServer

  import Batcher.Generator

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))

    {:ok, server: server}
  end

  test "admits a younger fittable waiting batch when older ones do not fit", %{server: server} do
    expect_json_response(
      server,
      :post,
      "/v1/batches",
      %{"id" => "batch_small", "status" => "validating"},
      200
    )

    model = "gpt-4o-mini"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _active_reserved =
      generate(
        seeded_batch(
          model: model,
          state: :openai_processing,
          estimated_input_tokens_total: 1_200_000
        )
      )

    older1 =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-old-1",
          estimated_input_tokens_total: 1_800_000,
          waiting_for_capacity_since_at: DateTime.add(now, -180, :second)
        )
      )

    older2 =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-old-2",
          estimated_input_tokens_total: 1_800_000,
          waiting_for_capacity_since_at: DateTime.add(now, -120, :second)
        )
      )

    smaller =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-small",
          estimated_input_tokens_total: 160_000,
          waiting_for_capacity_since_at: DateTime.add(now, -60, :second)
        )
      )

    assert {:ok, _} = DispatchWaitingForCapacity.run(%{subject: older1}, [], %{})

    assert Batching.get_batch_by_id!(older1.id).state == :waiting_for_capacity
    assert Batching.get_batch_by_id!(older2.id).state == :waiting_for_capacity
    assert Batching.get_batch_by_id!(smaller.id).state == :openai_processing

    assert Batching.get_batch_by_id!(older1.id).capacity_wait_reason == "insufficient_headroom"
    assert Batching.get_batch_by_id!(older2.id).capacity_wait_reason == "insufficient_headroom"
  end

  test "admits multiple waiting batches in one pass while headroom remains", %{server: server} do
    expect_json_response(
      server,
      :post,
      "/v1/batches",
      %{"id" => "batch_fit_1", "status" => "validating"},
      200
    )

    expect_json_response(
      server,
      :post,
      "/v1/batches",
      %{"id" => "batch_fit_2", "status" => "validating"},
      200
    )

    model = "gpt-4o-mini"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _active_reserved =
      generate(
        seeded_batch(
          model: model,
          state: :openai_processing,
          estimated_input_tokens_total: 1_200_000
        )
      )

    first_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-fit-1",
          estimated_input_tokens_total: 300_000,
          waiting_for_capacity_since_at: DateTime.add(now, -180, :second)
        )
      )

    second_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-fit-2",
          estimated_input_tokens_total: 200_000,
          waiting_for_capacity_since_at: DateTime.add(now, -120, :second)
        )
      )

    third_no_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-no-fit",
          estimated_input_tokens_total: 350_000,
          waiting_for_capacity_since_at: DateTime.add(now, -60, :second)
        )
      )

    assert {:ok, _} = DispatchWaitingForCapacity.run(%{subject: first_fit}, [], %{})

    assert Batching.get_batch_by_id!(first_fit.id).state == :openai_processing
    assert Batching.get_batch_by_id!(second_fit.id).state == :openai_processing
    assert Batching.get_batch_by_id!(third_no_fit.id).state == :waiting_for_capacity
  end

  test "keeps all waiting batches queued when none fit" do
    model = "gpt-4o-mini"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _active_reserved =
      generate(
        seeded_batch(
          model: model,
          state: :openai_processing,
          estimated_input_tokens_total: 1_950_000
        )
      )

    waiting1 =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-wait-1",
          estimated_input_tokens_total: 100_000,
          waiting_for_capacity_since_at: DateTime.add(now, -120, :second)
        )
      )

    waiting2 =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-wait-2",
          estimated_input_tokens_total: 200_000,
          waiting_for_capacity_since_at: DateTime.add(now, -60, :second)
        )
      )

    assert {:ok, _} = DispatchWaitingForCapacity.run(%{subject: waiting1}, [], %{})

    wait1 = Batching.get_batch_by_id!(waiting1.id)
    wait2 = Batching.get_batch_by_id!(waiting2.id)

    assert wait1.state == :waiting_for_capacity
    assert wait2.state == :waiting_for_capacity
    assert wait1.capacity_wait_reason == "insufficient_headroom"
    assert wait2.capacity_wait_reason == "insufficient_headroom"
  end

  test "selects oldest fittable batch deterministically", %{server: server} do
    expect_json_response(
      server,
      :post,
      "/v1/batches",
      %{"id" => "batch_oldest_fit", "status" => "validating"},
      200
    )

    model = "gpt-4o-mini"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _active_reserved =
      generate(
        seeded_batch(
          model: model,
          state: :openai_processing,
          estimated_input_tokens_total: 1_700_000
        )
      )

    oldest_no_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-oldest-no-fit",
          estimated_input_tokens_total: 900_000,
          waiting_for_capacity_since_at: DateTime.add(now, -180, :second)
        )
      )

    oldest_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-oldest-fit",
          estimated_input_tokens_total: 250_000,
          waiting_for_capacity_since_at: DateTime.add(now, -120, :second)
        )
      )

    newer_fit =
      generate(
        seeded_batch(
          model: model,
          state: :waiting_for_capacity,
          openai_input_file_id: "file-newer-fit",
          estimated_input_tokens_total: 200_000,
          waiting_for_capacity_since_at: DateTime.add(now, -60, :second)
        )
      )

    assert {:ok, _} = DispatchWaitingForCapacity.run(%{subject: oldest_no_fit}, [], %{})

    assert Batching.get_batch_by_id!(oldest_fit.id).state == :openai_processing
    assert Batching.get_batch_by_id!(newer_fit.id).state == :waiting_for_capacity
    assert Batching.get_batch_by_id!(oldest_no_fit.id).state == :waiting_for_capacity
  end
end
