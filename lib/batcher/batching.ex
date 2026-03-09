defmodule Batcher.Batching do
  @moduledoc """
  Ash domain entrypoint for batch and request resources.
  """
  use Ash.Domain,
    otp_app: :batcher

  resources do
    resource Batcher.Batching.Batch do
      define :create_batch, action: :create, args: [:model, :url]
      define :get_batch_by_id, action: :read, get_by: :id
      define :find_building_batch, action: :find_building_batch, args: [:model, :url]
      define :start_batch_upload, action: :start_upload
      define :wait_for_capacity, action: :wait_for_capacity
      define :touch_waiting_for_capacity, action: :touch_waiting_for_capacity
      define :read_batch_by_id, action: :read, get_by: :id
      define :list_batches, action: :read
      define :list_batches_by_ids, action: :list_by_ids, args: [:ids]

      define :search_batches,
        action: :search,
        args: [:query]

      define :count_batches_for_search,
        action: :count_for_search,
        args: [:query]

      define :cancel_batch, action: :cancel
      define :restart_batch, action: :restart
      define :handle_batch_token_limit_exceeded, action: :handle_token_limit_exceeded
      define :fail_batch_token_limit_exhausted, action: :fail_token_limit_exhausted
      define :destroy_batch, action: :destroy
      define :redeliver_batch, action: :redeliver, args: [:id]
      define :redeliver_failed_batch, action: :redeliver_failed, args: [:id]
    end

    resource Batcher.Batching.Request do
      define :create_request, action: :create
      define :get_request_by_id, action: :read, get_by: :id

      define :get_request_by_custom_id,
        action: :get_request_by_custom_id,
        args: [:batch_id, :custom_id]

      define :list_requests_by_custom_id,
        action: :list_by_custom_id,
        args: [:custom_id]

      define :list_requests_in_batch, action: :list_requests_in_batch, args: [:batch_id]
      define :list_requests_paginated, action: :list_paginated, args: [:batch_id, :skip, :limit]

      define :search_requests,
        action: :search,
        args: [:query]

      define :count_requests_for_search,
        action: :count_for_search,
        args: [:query]

      define :deliver_request, action: :deliver
      define :update_request_delivery_config, action: :update_delivery_config
      define :retry_request_delivery, action: :retry_delivery
      define :destroy_request, action: :destroy
    end

    # Transition resources (internal only)
    resource Batcher.Batching.BatchTransition

    resource Batcher.Batching.RequestDeliveryAttempt do
      define :list_delivery_attempts_paginated,
        action: :list_paginated,
        args: [:request_id, :skip, :limit]
    end
  end

  @doc """
  Executes manual one-shot redelivery for a request.

  Returns `{:error, :invalid_batch_state}` when the request's batch is currently delivering.
  """
  @spec manual_redeliver_request(map()) :: {:ok, map()} | {:error, term()}
  def manual_redeliver_request(request) do
    with {:ok, request_with_batch} <- ensure_request_batch_loaded(request),
         :ok <- ensure_batch_not_delivering(request_with_batch.batch),
         {:ok, updated_request} <- retry_request_delivery(request_with_batch) do
      {:ok, updated_request}
    end
  end

  defp ensure_request_batch_loaded(%{batch: %{state: _}} = request), do: {:ok, request}

  defp ensure_request_batch_loaded(%{id: id}) do
    {:ok, get_request_by_id!(id, load: [:batch])}
  rescue
    error -> {:error, error}
  end

  defp ensure_batch_not_delivering(%{state: :delivering}), do: {:error, :invalid_batch_state}
  defp ensure_batch_not_delivering(_batch), do: :ok
end
