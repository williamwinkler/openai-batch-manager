defmodule Batcher.Batching do
  use Ash.Domain,
    otp_app: :batcher

  resources do
    resource Batcher.Batching.Batch do
      define :create_batch, action: :create, args: [:model, :url]
      define :get_batch_by_id, action: :read, get_by: :id
      define :find_building_batch, action: :find_building_batch, args: [:model, :url]
      define :start_batch_upload, action: :start_upload
    end

    resource Batcher.Batching.Request do
      define :create_request, action: :create
    end

    # Transition resources (internal only)
    resource Batcher.Batching.BatchTransition
    resource Batcher.Batching.RequestTransition
  end
end
