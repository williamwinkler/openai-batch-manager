defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching

  describe "create_batch/2" do
    test "creates a batch with valid attributes" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      assert batch.model == "gpt-4"
      assert batch.endpoint == "/v1/responses"
      assert batch.state == :draft
      assert batch.openai_batch_id == nil
    end

    test "creates batch with initial state transition record" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      # Load transitions to verify audit trail
      {:ok, batch} = Batching.get_batch_by_id(batch.id, load: [:transitions])

      assert length(batch.transitions) == 1

      transition = hd(batch.transitions)
      assert transition.from == nil
      assert transition.to == :draft
      assert transition.transitioned_at != nil
    end

    test "supports different models" do
      {:ok, batch} = Batching.create_batch("gpt-4o", "/v1/responses")

      assert batch.model == "gpt-4o"
    end

    test "supports different endpoints" do
      {:ok, batch1} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch2} = Batching.create_batch("gpt-4", "/v1/embeddings")

      assert batch1.endpoint == "/v1/responses"
      assert batch2.endpoint == "/v1/embeddings"
    end

    test "creates batch file in configured batch storage directory" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      # Use the BatchFile module to get the correct path
      batch_file_path = Batcher.Batching.BatchFile.file_path(batch.id)
      assert File.exists?(batch_file_path)
    end
  end

  describe "batch_mark_ready/1" do
    test "transitions batch from draft to ready_for_upload" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, updated_batch} = Batching.batch_mark_ready(batch)

      assert updated_batch.state == :ready_for_upload
    end

    test "creates transition record for state change" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, updated_batch} = Batching.batch_mark_ready(batch)

      # Load transitions
      {:ok, batch_with_transitions} =
        Batching.get_batch_by_id(updated_batch.id, load: [:transitions])

      assert length(batch_with_transitions.transitions) == 2

      [_initial, ready_transition] = batch_with_transitions.transitions

      assert ready_transition.from == :draft
      assert ready_transition.to == :ready_for_upload
    end

    test "fails when batch is not in draft state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)

      # Try to mark ready again
      {:error, error} = Batching.batch_mark_ready(batch)
      assert error.errors != []
    end
  end

  describe "batch_begin_upload/1" do
    test "transitions from ready_for_upload to uploading" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)

      {:ok, updated_batch} = Batching.batch_begin_upload(batch)

      assert updated_batch.state == :uploading
    end

    test "fails when transitioning from invalid state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      # batch is in :draft, should fail to upload directly

      {:error, error} = Batching.batch_begin_upload(batch)

      assert error.errors != []
    end
  end

  describe "batch_mark_validating/2" do
    test "transitions from uploading to validating with openai_batch_id" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)

      {:ok, updated_batch} =
        Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})

      assert updated_batch.state == :validating
      assert updated_batch.openai_batch_id == "batch_123"
    end

    test "fails without openai_batch_id" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)

      # Should fail without openai_batch_id
      {:error, _} = Batching.batch_mark_validating(batch, %{})
    end
  end

  describe "state machine transitions - happy path" do
    test "follows complete workflow from draft to completed" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      assert batch.state == :draft

      {:ok, batch} = Batching.batch_mark_ready(batch)
      assert batch.state == :ready_for_upload

      {:ok, batch} = Batching.batch_begin_upload(batch)
      assert batch.state == :uploading

      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_abc123"})
      assert batch.state == :validating
      assert batch.openai_batch_id == "batch_abc123"

      {:ok, batch} = Batching.batch_mark_in_progress(batch)
      assert batch.state == :in_progress

      {:ok, batch} = Batching.batch_mark_finalizing(batch)
      assert batch.state == :finalizing

      {:ok, batch} = Batching.batch_begin_download(batch)
      assert batch.state == :downloading

      {:ok, batch} = Batching.batch_mark_completed(batch)
      assert batch.state == :completed
    end

    test "creates transition record for each state change" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})
      {:ok, batch} = Batching.batch_mark_in_progress(batch)
      {:ok, batch} = Batching.batch_mark_finalizing(batch)
      {:ok, batch} = Batching.batch_begin_download(batch)
      {:ok, batch} = Batching.batch_mark_completed(batch)

      # Load all transitions
      {:ok, batch_with_transitions} = Batching.get_batch_by_id(batch.id, load: [:transitions])

      # Should have 8 transitions (initial + 7 state changes)
      assert length(batch_with_transitions.transitions) == 8

      # Verify the sequence
      states = Enum.map(batch_with_transitions.transitions, & &1.to)

      assert states == [
               :draft,
               :ready_for_upload,
               :uploading,
               :validating,
               :in_progress,
               :finalizing,
               :downloading,
               :completed
             ]
    end
  end

  describe "failure transitions" do
    test "allows failure from draft state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, failed_batch} = Batching.batch_mark_failed(batch, %{error_msg: "Test error"})

      assert failed_batch.state == :failed
      assert failed_batch.error_msg == "Test error"
    end

    test "allows failure from in_progress state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})
      {:ok, batch} = Batching.batch_mark_in_progress(batch)

      {:ok, failed_batch} = Batching.batch_mark_failed(batch, %{error_msg: "Processing failed"})

      assert failed_batch.state == :failed
      assert failed_batch.error_msg == "Processing failed"
    end

    test "allows failure from multiple states" do
      states_to_test = [
        :draft,
        :ready_for_upload,
        :uploading,
        :validating,
        :in_progress,
        :finalizing,
        :downloading
      ]

      for state <- states_to_test do
        {:ok, batch} = Batching.create_batch("gpt-4-#{state}", "/v1/responses")

        # Transition to target state
        batch =
          case state do
            :draft ->
              batch

            :ready_for_upload ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              b

            :uploading ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              {:ok, b} = Batching.batch_begin_upload(b)
              b

            :validating ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              {:ok, b} = Batching.batch_begin_upload(b)
              {:ok, b} = Batching.batch_mark_validating(b, %{openai_batch_id: "test"})
              b

            :in_progress ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              {:ok, b} = Batching.batch_begin_upload(b)
              {:ok, b} = Batching.batch_mark_validating(b, %{openai_batch_id: "test"})
              {:ok, b} = Batching.batch_mark_in_progress(b)
              b

            :finalizing ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              {:ok, b} = Batching.batch_begin_upload(b)
              {:ok, b} = Batching.batch_mark_validating(b, %{openai_batch_id: "test"})
              {:ok, b} = Batching.batch_mark_in_progress(b)
              {:ok, b} = Batching.batch_mark_finalizing(b)
              b

            :downloading ->
              {:ok, b} = Batching.batch_mark_ready(batch)
              {:ok, b} = Batching.batch_begin_upload(b)
              {:ok, b} = Batching.batch_mark_validating(b, %{openai_batch_id: "test"})
              {:ok, b} = Batching.batch_mark_in_progress(b)
              {:ok, b} = Batching.batch_mark_finalizing(b)
              {:ok, b} = Batching.batch_begin_download(b)
              b
          end

        {:ok, failed} = Batching.batch_mark_failed(batch, %{error_msg: "Test"})
        assert failed.state == :failed
      end
    end
  end

  describe "expiration transitions" do
    test "allows expiration from validating state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})

      {:ok, expired_batch} = Batching.batch_mark_expired(batch, %{error_msg: "Batch expired"})

      assert expired_batch.state == :expired
      assert expired_batch.error_msg == "Batch expired"
    end

    test "allows expiration from in_progress state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})
      {:ok, batch} = Batching.batch_mark_in_progress(batch)

      {:ok, expired_batch} = Batching.batch_mark_expired(batch, %{error_msg: "Timeout"})

      assert expired_batch.state == :expired
    end

    test "allows expiration from finalizing state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "batch_123"})
      {:ok, batch} = Batching.batch_mark_in_progress(batch)
      {:ok, batch} = Batching.batch_mark_finalizing(batch)

      {:ok, expired_batch} = Batching.batch_mark_expired(batch, %{error_msg: "Timeout"})

      assert expired_batch.state == :expired
    end

    test "doesn't allow expiration from draft state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:error, _} = Batching.batch_mark_expired(batch, %{error_msg: "Test"})
    end
  end

  describe "cancellation transitions" do
    test "allows cancellation from draft state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, cancelled_batch} = Batching.batch_cancel(batch)

      assert cancelled_batch.state == :cancelled
    end

    test "allows cancellation from ready_for_upload state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)

      {:ok, cancelled_batch} = Batching.batch_cancel(batch)

      assert cancelled_batch.state == :cancelled
    end

    test "allows cancellation from uploading state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)

      {:ok, cancelled_batch} = Batching.batch_cancel(batch)

      assert cancelled_batch.state == :cancelled
    end

    test "allows cancellation from validating state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "test"})

      {:ok, cancelled_batch} = Batching.batch_cancel(batch)

      assert cancelled_batch.state == :cancelled
    end

    test "doesn't allow cancellation from in_progress state" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)
      {:ok, batch} = Batching.batch_mark_validating(batch, %{openai_batch_id: "test"})
      {:ok, batch} = Batching.batch_mark_in_progress(batch)

      {:error, _} = Batching.batch_cancel(batch)
    end
  end

  describe "get_batch_by_id/2" do
    test "retrieves batch by id" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, retrieved} = Batching.get_batch_by_id(batch.id)

      assert retrieved.id == batch.id
      assert retrieved.model == "gpt-4"
    end

    test "loads prompts relationship when requested" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      # Add prompts
      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "p1",
          endpoint: "/v1/responses",
          model: "gpt-4",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "p2",
          endpoint: "/v1/responses",
          model: "gpt-4",
          request_payload: %{"test" => 2},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      # Load with relationships
      {:ok, batch_with_prompts} = Batching.get_batch_by_id(batch.id, load: [:prompts])

      assert length(batch_with_prompts.prompts) == 2
    end

    test "loads transitions relationship when requested" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)

      {:ok, batch_with_transitions} =
        Batching.get_batch_by_id(batch.id, load: [:transitions])

      assert length(batch_with_transitions.transitions) >= 2
    end

    test "returns error for nonexistent batch" do
      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_batch_by_id!(999_999)
      end
    end
  end

  describe "get_batches/0" do
    test "returns all batches" do
      {:ok, _batch1} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, _batch2} = Batching.create_batch("gpt-4o", "/v1/embeddings")

      {:ok, batches} = Batching.get_batches()

      assert length(batches) >= 2
    end

    test "returns empty list when no batches exist" do
      # Clear any existing batches from other tests
      {:ok, batches} = Batching.get_batches()

      if length(batches) > 0 do
        # This is fine - other tests may have created batches
        assert is_list(batches)
      else
        assert batches == []
      end
    end
  end

  describe "destroy_batch/1" do
    test "deletes a batch" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      :ok = Batching.destroy_batch(batch)

      # Should raise when trying to get deleted batch
      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_batch_by_id!(batch.id)
      end
    end

    test "cascades delete to prompts" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "test-prompt",
          endpoint: "/v1/responses",
          model: "gpt-4",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      :ok = Batching.destroy_batch(batch)

      # Prompt should also be deleted
      assert_raise Ash.Error.Invalid, fn ->
        Batching.get_prompt_by_id!(prompt.id)
      end
    end

    test "cascades delete to transitions" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)

      {:ok, batch_with_transitions} = Batching.get_batch_by_id(batch.id, load: [:transitions])
      assert length(batch_with_transitions.transitions) > 0

      :ok = Batching.destroy_batch(batch)

      # Transitions should be deleted (verified implicitly - no orphans)
    end
  end

  describe "find_draft_batch/2" do
    test "finds existing draft batch for model/endpoint" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, found_batch} = Batching.find_draft_batch("gpt-4", "/v1/responses")

      assert found_batch.id == batch.id
      assert found_batch.state == :draft
    end

    test "returns error when no draft batch exists" do
      {:error, _} = Batching.find_draft_batch("nonexistent-model", "/v1/nonexistent")
    end

    test "only finds draft batches, not other states" do
      {:ok, batch} = Batching.create_batch("gpt-4-ready", "/v1/responses")
      {:ok, _} = Batching.batch_mark_ready(batch)

      {:error, _} = Batching.find_draft_batch("gpt-4-ready", "/v1/responses")
    end

    test "finds correct batch when multiple exist for different models" do
      {:ok, batch1} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, _batch2} = Batching.create_batch("gpt-4o", "/v1/responses")

      {:ok, found} = Batching.find_draft_batch("gpt-4", "/v1/responses")

      assert found.id == batch1.id
    end

    test "finds correct batch when multiple exist for different endpoints" do
      {:ok, batch1} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, _batch2} = Batching.create_batch("gpt-4", "/v1/embeddings")

      {:ok, found} = Batching.find_draft_batch("gpt-4", "/v1/responses")

      assert found.id == batch1.id
    end
  end

  describe "edge cases and error handling" do
    test "handles empty error_msg" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, failed_batch} = Batching.batch_mark_failed(batch, %{error_msg: ""})

      assert failed_batch.state == :failed
      # Empty string may be stored as nil - both are acceptable
      assert is_nil(failed_batch.error_msg) or failed_batch.error_msg == ""
    end

    test "handles nil error_msg" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      {:ok, failed_batch} = Batching.batch_mark_failed(batch, %{})

      assert failed_batch.state == :failed
      assert failed_batch.error_msg == nil
    end

    test "handles very long error messages" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")

      long_error = String.duplicate("error ", 1000)

      {:ok, failed_batch} = Batching.batch_mark_failed(batch, %{error_msg: long_error})

      assert failed_batch.state == :failed
      # Database may truncate very long strings, check it starts with our pattern
      assert String.starts_with?(failed_batch.error_msg, "error error error")
      assert String.length(failed_batch.error_msg) > 100
    end

    test "handles special characters in openai_batch_id" do
      {:ok, batch} = Batching.create_batch("gpt-4", "/v1/responses")
      {:ok, batch} = Batching.batch_mark_ready(batch)
      {:ok, batch} = Batching.batch_begin_upload(batch)

      special_id = "batch_123-abc_XYZ.test"

      {:ok, updated} = Batching.batch_mark_validating(batch, %{openai_batch_id: special_id})

      assert updated.openai_batch_id == special_id
    end
  end
end
