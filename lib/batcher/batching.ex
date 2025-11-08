defmodule Batcher.Batching do
  use Ash.Domain,
    otp_app: :batcher

  resources do
    resource Batcher.Batching.Batch do
      define :create_batch, action: :create, args: [:model, :endpoint]
      define :get_batches, action: :read
      define :get_batch_by_id, action: :read, get_by: :id
      define :find_draft_batch, action: :find_draft_batch, args: [:model, :endpoint]
      define :destroy_batch, action: :destroy

      # Transitions
      define :batch_mark_ready, action: :mark_ready
      define :batch_begin_upload, action: :begin_upload
      define :batch_mark_validating, action: :mark_validating
      define :batch_mark_in_progress, action: :mark_in_progress
      define :batch_mark_finalizing, action: :mark_finalizing
      define :batch_begin_download, action: :begin_download
      define :batch_mark_completed, action: :mark_completed
      define :batch_mark_failed, action: :mark_failed
      define :batch_mark_expired, action: :mark_expired
      define :batch_cancel, action: :cancel
    end

    resource Batcher.Batching.Prompt do
      # Create action (called by BatchBuilder)
      define :create_prompt, action: :create

      # Query actions
      define :get_prompt_by_id, action: :read, get_by: :id
      define :get_prompts, action: :read

      # Transitions
      define :prompt_begin_processing, action: :begin_processing
      define :prompt_complete_processing, action: :complete_processing
      define :prompt_begin_delivery, action: :begin_delivery
      define :prompt_complete_delivery, action: :complete_delivery
      define :prompt_mark_failed, action: :mark_failed
      define :prompt_mark_expired, action: :mark_expired
      define :prompt_cancel, action: :cancel
    end

    # Transition resources (internal only)
    resource Batcher.Batching.BatchTransition
    resource Batcher.Batching.PromptTransition
  end
end
