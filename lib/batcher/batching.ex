defmodule Batcher.Batching do
  use Ash.Domain,
    otp_app: :batcher

  resources do
    resource Batcher.Batching.Batch do
      define :create_batch, action: :create, args: [:model, :url]
      define :get_batch_by_id, action: :read, get_by: :id
      define :find_building_batch, action: :find_building_batch, args: [:model, :url]
      define :start_batch_upload, action: :start_upload
      define :read_batch_by_id, action: :read, get_by: :id
      define :list_batches, action: :read

      define :search_batches,
        action: :search,
        args: [:query],
        default_options: [load: [:request_count, :size_bytes]]

      define :cancel_batch, action: :cancel
      define :destroy_batch, action: :destroy
      define :redeliver_batch, action: :redeliver, args: [:id]
    end

    resource Batcher.Batching.Request do
      define :create_request, action: :create
      define :get_request_by_id, action: :read, get_by: :id

      define :get_request_by_custom_id,
        action: :get_request_by_custom_id,
        args: [:batch_id, :custom_id]

      define :list_requests_in_batch, action: :list_requests_in_batch, args: [:batch_id]
      define :list_requests_paginated, action: :list_paginated, args: [:batch_id, :skip, :limit]

      define :search_requests,
        action: :search,
        args: [:query]

      define :deliver_request, action: :deliver
      define :update_request_delivery_config, action: :update_delivery_config
      define :retry_request_delivery, action: :retry_delivery
    end

    # Transition resources (internal only)
    resource Batcher.Batching.BatchTransition

    resource Batcher.Batching.RequestDeliveryAttempt do
      define :list_delivery_attempts_paginated,
        action: :list_paginated,
        args: [:request_id, :skip, :limit]
    end
  end
end
