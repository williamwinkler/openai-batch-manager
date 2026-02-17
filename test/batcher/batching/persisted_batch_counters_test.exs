defmodule Batcher.Batching.PersistedBatchCountersTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Repo

  @delivery_config %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}

  test "request create increments batch counters" do
    {:ok, batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    custom_id = "counter_create_#{System.unique_integer([:positive])}"

    assert batch.request_count == 0
    assert batch.size_bytes == 0
    assert batch.estimated_input_tokens_total == 0
    assert batch.estimated_request_input_tokens_total == 0

    {:ok, request} =
      Batching.create_request(%{
        batch_id: batch.id,
        custom_id: custom_id,
        url: batch.url,
        model: batch.model,
        delivery_config: @delivery_config,
        request_payload: %{
          custom_id: custom_id,
          method: "POST",
          url: batch.url,
          body: %{model: batch.model, input: "hello"}
        }
      })

    updated_batch = Batching.get_batch_by_id!(batch.id)

    assert updated_batch.request_count == 1
    assert updated_batch.size_bytes == request.request_payload_size
    assert updated_batch.estimated_input_tokens_total == request.estimated_input_tokens

    assert updated_batch.estimated_request_input_tokens_total ==
             request.estimated_request_input_tokens
  end

  test "request delete decrements batch counters" do
    {:ok, batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    custom_id = "counter_delete_#{System.unique_integer([:positive])}"

    {:ok, request} =
      Batching.create_request(%{
        batch_id: batch.id,
        custom_id: custom_id,
        url: batch.url,
        model: batch.model,
        delivery_config: @delivery_config,
        request_payload: %{
          custom_id: custom_id,
          method: "POST",
          url: batch.url,
          body: %{model: batch.model, input: "hello"}
        }
      })

    assert :ok = Batching.destroy_request(request)

    updated_batch = Batching.get_batch_by_id!(batch.id)
    assert updated_batch.request_count == 0
    assert updated_batch.size_bytes == 0
    assert updated_batch.estimated_input_tokens_total == 0
    assert updated_batch.estimated_request_input_tokens_total == 0
  end

  test "updating request_payload_size adjusts size_bytes" do
    {:ok, batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    custom_id = "counter_size_update_#{System.unique_integer([:positive])}"

    {:ok, request} =
      Batching.create_request(%{
        batch_id: batch.id,
        custom_id: custom_id,
        url: batch.url,
        model: batch.model,
        delivery_config: @delivery_config,
        request_payload: %{
          custom_id: custom_id,
          method: "POST",
          url: batch.url,
          body: %{model: batch.model, input: "hello"}
        }
      })

    new_size = request.request_payload_size + 256

    Repo.query!(
      "UPDATE requests SET request_payload_size = ?1 WHERE id = ?2",
      [new_size, request.id]
    )

    updated_batch = Batching.get_batch_by_id!(batch.id)
    assert updated_batch.request_count == 1
    assert updated_batch.size_bytes == new_size
    assert updated_batch.estimated_input_tokens_total == request.estimated_input_tokens

    assert updated_batch.estimated_request_input_tokens_total ==
             request.estimated_request_input_tokens
  end

  test "moving request between batches updates both counters" do
    {:ok, source_batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    {:ok, target_batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    custom_id = "counter_move_#{System.unique_integer([:positive])}"

    {:ok, request} =
      Batching.create_request(%{
        batch_id: source_batch.id,
        custom_id: custom_id,
        url: source_batch.url,
        model: source_batch.model,
        delivery_config: @delivery_config,
        request_payload: %{
          custom_id: custom_id,
          method: "POST",
          url: source_batch.url,
          body: %{model: source_batch.model, input: "hello"}
        }
      })

    Repo.query!(
      "UPDATE requests SET batch_id = ?1 WHERE id = ?2",
      [target_batch.id, request.id]
    )

    source_updated = Batching.get_batch_by_id!(source_batch.id)
    target_updated = Batching.get_batch_by_id!(target_batch.id)

    assert source_updated.request_count == 0
    assert source_updated.size_bytes == 0
    assert source_updated.estimated_input_tokens_total == 0
    assert source_updated.estimated_request_input_tokens_total == 0
    assert target_updated.request_count == 1
    assert target_updated.size_bytes == request.request_payload_size
    assert target_updated.estimated_input_tokens_total == request.estimated_input_tokens

    assert target_updated.estimated_request_input_tokens_total ==
             request.estimated_request_input_tokens
  end

  test "counter changes roll back with transaction rollback" do
    {:ok, batch} = Batching.create_batch("gpt-4o-mini", "/v1/responses")
    before = Batching.get_batch_by_id!(batch.id)

    custom_id = "counter_tx_rollback_#{System.unique_integer([:positive])}"

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               {:ok, _request} =
                 Batching.create_request(%{
                   batch_id: batch.id,
                   custom_id: custom_id,
                   url: batch.url,
                   model: batch.model,
                   delivery_config: @delivery_config,
                   request_payload: %{
                     custom_id: custom_id,
                     method: "POST",
                     url: batch.url,
                     body: %{model: batch.model, input: "hello"}
                   }
                 })

               Repo.rollback(:forced_rollback)
             end)

    after_batch = Batching.get_batch_by_id!(batch.id)

    assert after_batch.request_count == before.request_count
    assert after_batch.size_bytes == before.size_bytes
    assert after_batch.estimated_input_tokens_total == before.estimated_input_tokens_total

    assert after_batch.estimated_request_input_tokens_total ==
             before.estimated_request_input_tokens_total

    assert {:ok, []} = Batching.list_requests_by_custom_id(custom_id)
  end
end
