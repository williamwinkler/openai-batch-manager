defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  import Batcher.BatchingFixtures

  describe "create_batch/2" do
    test "creates a batch with valid attributes" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      assert batch.provider == :openai
      assert batch.model == "gpt-4"
      assert batch.state == :draft
      assert batch.provider_batch_id == nil
    end

    test "creates batch with initial state transition record" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      # Load transitions to verify audit trail
      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:transitions])

      assert length(batch.transitions) == 1

      transition = hd(batch.transitions)
      assert transition.from == nil
      assert transition.to == :draft
      assert transition.transitioned_at != nil
    end

    test "supports different models" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4o")

      assert batch.provider == :openai
      assert batch.model == "gpt-4o"
    end
  end

  describe "batch_mark_ready/1" do
    test "transitions batch from draft to ready_for_upload" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      {:ok, updated_batch} = Batching.batch_mark_ready(batch)

      assert updated_batch.state == :ready_for_upload
    end

    test "creates transition record for state change" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      {:ok, updated_batch} = Batching.batch_mark_ready(batch)

      # Load transitions
      {:ok, batch_with_transitions} =
        Batching.get_batch_by_id(updated_batch.id, load: [:transitions])

      assert length(batch_with_transitions.transitions) == 2

      [_initial, ready_transition] = batch_with_transitions.transitions

      assert ready_transition.from == :draft
      assert ready_transition.to == :ready_for_upload
    end
  end

  describe "batch_begin_upload/1" do
    test "transitions from ready_for_upload to uploading" do
      batch = batch_fixture(state: :ready_for_upload)

      {:ok, updated_batch} = Batching.batch_begin_upload(batch)

      assert updated_batch.state == :uploading
    end

    test "fails when transitioning from invalid state" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")
      # batch is in :draft, should fail to upload directly

      {:error, error} = Batching.batch_begin_upload(batch)

      assert error.errors != []
    end
  end

  describe "batch_mark_validating/2" do
    test "transitions from uploading to validating with provider_batch_id" do
      batch = batch_fixture(state: :uploading)

      {:ok, updated_batch} =
        Batching.batch_mark_validating(batch, %{provider_batch_id: "batch_123"})

      assert updated_batch.state == :validating
      assert updated_batch.provider_batch_id == "batch_123"
    end
  end

  describe "state machine transitions" do
    test "follows complete happy path workflow" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")
      assert batch.state == :draft

      {:ok, batch} = Batching.batch_mark_ready(batch)
      assert batch.state == :ready_for_upload

      {:ok, batch} = Batching.batch_begin_upload(batch)
      assert batch.state == :uploading

      {:ok, batch} = Batching.batch_mark_validating(batch, %{provider_batch_id: "batch_abc123"})
      assert batch.state == :validating
      assert batch.provider_batch_id == "batch_abc123"

      {:ok, batch} = Batching.batch_mark_in_progress(batch)
      assert batch.state == :in_progress

      {:ok, batch} = Batching.batch_mark_finalizing(batch)
      assert batch.state == :finalizing

      {:ok, batch} = Batching.batch_begin_download(batch)
      assert batch.state == :downloading

      {:ok, batch} = Batching.batch_mark_completed(batch)
      assert batch.state == :completed
    end

    test "allows failure from in_progress state" do
      batch = batch_fixture(state: :in_progress)

      {:ok, failed_batch} = Batching.batch_mark_failed(batch)

      assert failed_batch.state == :failed
    end

    test "allows cancellation from ready_for_upload state" do
      batch = batch_fixture(state: :ready_for_upload)

      {:ok, cancelled_batch} = Batching.batch_cancel(batch)

      assert cancelled_batch.state == :cancelled
    end

    test "allows expiration from in_progress state" do
      batch = batch_fixture(state: :in_progress)

      {:ok, expired_batch} = Batching.batch_mark_expired(batch)

      assert expired_batch.state == :expired
    end
  end

  describe "get_batch_by_id/2" do
    test "retrieves batch by id" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      {:ok, retrieved} = Batching.get_batch_by_id(batch.id)

      assert retrieved.id == batch.id
      assert retrieved.provider == :openai
    end

    test "loads relationships when requested" do
      {batch, _prompts} = batch_with_prompts_fixture(%{prompt_count: 2})

      # Load with relationships
      {:ok, batch_with_prompts} =
        Batching.get_batch_by_id(batch.id, load: [:prompts, :transitions])

      assert length(batch_with_prompts.prompts) == 2
      assert length(batch_with_prompts.transitions) >= 1
    end
  end

  describe "get_batches/0" do
    test "returns all batches" do
      {:ok, _batch1} = Batching.create_batch(:openai, "gpt-4")
      {:ok, _batch2} = Batching.create_batch(:openai, "gpt-4o")

      {:ok, batches} = Batching.get_batches()

      assert length(batches) >= 2
    end
  end

  describe "destroy_batch/1" do
    test "deletes a batch" do
      {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

      :ok = Batching.destroy_batch(batch)

      # Should raise when trying to get deleted batch (raises Ash.Error.Invalid with NotFound inside)
      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_batch_by_id!(batch.id)
      end
    end
  end

  describe "using fixtures" do
    test "creates batch with fixture helper" do
      batch = batch_fixture()

      assert batch.provider == :openai
      assert batch.model == "gpt-4"
      assert batch.state == :draft
    end

    test "creates batch in specific state" do
      batch = batch_fixture(state: :ready_for_upload)

      assert batch.state == :ready_for_upload
    end

    test "creates batch with custom model" do
      batch = batch_fixture(model: "gpt-4o")

      assert batch.model == "gpt-4o"
    end

    test "creates batch with prompts" do
      {batch, prompts} = batch_with_prompts_fixture(%{prompt_count: 3})

      assert length(prompts) == 3
      assert Enum.all?(prompts, fn p -> p.batch_id == batch.id end)
    end
  end
end
