defmodule Batcher.BatchBuilderTest do
  use Batcher.DataCase, async: false

  alias Batcher.{BatchBuilder, Batching}

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))
    {:ok, server: server}
  end

  describe "BatchBuilder lifecycle" do
    test "does not create a new batch when uploading (restart: :temporary prevents auto-restart)" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      # Add a request - this creates a BatchBuilder and batch
      request_data = %{
        custom_id: "test_req_1",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)

      # Verify batch is in building state
      {:ok, batch} = Batching.get_batch_by_id(request.batch_id)
      assert batch.state == :building

      # Record initial batch count
      {:ok, initial_batches} = Batching.list_batches()
      initial_count = length(initial_batches)

      # Verify BatchBuilder is registered and alive
      [{pid, _}] = Registry.lookup(Batcher.BatchRegistry, {url, model})
      assert Process.alive?(pid)

      # Upload the batch - synchronous call
      :ok = BatchBuilder.upload_batch(url, model)

      # BatchBuilder should be unregistered
      assert Registry.lookup(Batcher.BatchRegistry, {url, model}) == []

      # No new batch should have been created (the key fix: restart: :temporary)
      {:ok, final_batches} = Batching.list_batches()
      assert length(final_batches) == initial_count

      # Original batch should be in uploading state
      {:ok, updated_batch} = Batching.get_batch_by_id(batch.id)
      assert updated_batch.state == :uploading
    end
  end
end
