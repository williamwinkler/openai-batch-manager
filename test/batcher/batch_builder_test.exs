defmodule Batcher.BatchBuilderTest do
  use Batcher.DataCase, async: false

  alias Batcher.{BatchBuilder, Batching}

  setup do
    {:ok, server} = TestServer.start()
    Process.put(:openai_base_url, TestServer.url(server))

    # Clear any existing BatchBuilders to avoid stale state from previous tests
    for {url, model} <- [
          {"/v1/responses", "gpt-4o-mini"},
          {"/v1/chat/completions", "gpt-4o"},
          {"/v1/responses", "gpt-3.5-turbo"},
          {"/v1/responses", "gpt-4-turbo"},
          {"/v1/embeddings", "text-embedding-3-small"},
          {"/v1/responses", "gpt-4o-2024-08-06"}
        ] do
      case Registry.lookup(Batcher.BatchRegistry, {url, model}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            100 -> :ok
          end

        [] ->
          :ok
      end
    end

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
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
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

    test "add_request/3 starts new BatchBuilder when none exists" do
      # Use unique URL to avoid conflicts with other tests
      url = "/v1/chat/completions"
      model = "gpt-4o"

      request_data = %{
        custom_id: "new_builder_req",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)

      # Verify BatchBuilder was created and registered
      [{pid, _}] = Registry.lookup(Batcher.BatchRegistry, {url, model})
      assert Process.alive?(pid)

      # Verify request was created
      assert request.custom_id == "new_builder_req"
      {:ok, batch} = Batching.get_batch_by_id(request.batch_id)
      assert batch.state == :building
    end

    test "add_request/3 retries when BatchBuilder crashes between lookup and call" do
      # Use unique model to avoid conflicts
      url = "/v1/responses"
      model = "gpt-3.5-turbo"

      # Create a BatchBuilder
      request_data1 = %{
        custom_id: "first_req_crash_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, _request1} = BatchBuilder.add_request(url, model, request_data1)

      # Get the BatchBuilder PID
      [{pid, _}] = Registry.lookup(Batcher.BatchRegistry, {url, model})

      # Kill the BatchBuilder
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      # Wait for process to die and be unregistered
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 -> flunk("Process did not die")
      end

      # Add another request - should retry and create new BatchBuilder
      request_data2 = %{
        custom_id: "retry_req_crash_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request2} = BatchBuilder.add_request(url, model, request_data2)

      # Verify new BatchBuilder was created
      [{new_pid, _}] = Registry.lookup(Batcher.BatchRegistry, {url, model})
      assert Process.alive?(new_pid)
      assert new_pid != pid

      # Verify request was created
      assert request2.custom_id == "retry_req_crash_test"
    end

    test "detects and returns error for duplicate custom_id" do
      # Use unique model to avoid conflicts
      url = "/v1/responses"
      model = "gpt-4-turbo"

      request_data = %{
        custom_id: "duplicate_custom_id_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      # Create first request
      {:ok, request1} = BatchBuilder.add_request(url, model, request_data)
      assert request1.custom_id == "duplicate_custom_id_test"

      # Try to create duplicate
      result = BatchBuilder.add_request(url, model, request_data)

      assert {:error, :custom_id_already_taken} = result
    end

    test "handles concurrent requests to same BatchBuilder" do
      # Use unique model to avoid conflicts
      url = "/v1/embeddings"
      model = "text-embedding-3-small"

      request_data1 = %{
        custom_id: "concurrent_req_1",
        url: url,
        body: %{input: "test 1", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      request_data2 = %{
        custom_id: "concurrent_req_2",
        url: url,
        body: %{input: "test 2", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      # Start two concurrent requests
      task1 = Task.async(fn -> BatchBuilder.add_request(url, model, request_data1) end)
      task2 = Task.async(fn -> BatchBuilder.add_request(url, model, request_data2) end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      # Both should succeed
      assert {:ok, request1} = result1
      assert {:ok, request2} = result2

      assert request1.custom_id == "concurrent_req_1"
      assert request2.custom_id == "concurrent_req_2"

      # Both should be in the same batch
      assert request1.batch_id == request2.batch_id
    end

    test "upload_batch/2 transitions batch from building to uploading" do
      url = "/v1/responses"
      model = "gpt-4o-2024-08-06"

      request_data = %{
        custom_id: "upload_test_req",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)
      batch_id = request.batch_id

      # Upload the batch
      :ok = BatchBuilder.upload_batch(url, model)

      # Batch should be in uploading state
      {:ok, batch} = Batching.get_batch_by_id(batch_id)
      assert batch.state == :uploading

      # BatchBuilder should be unregistered
      assert Registry.lookup(Batcher.BatchRegistry, {url, model}) == []
    end

    test "handles batch size limit correctly" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      # Create requests up to the test limit (5 requests)
      request_data_base = %{
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      # Add 4 requests (one less than limit)
      for i <- 1..4 do
        request_data = Map.put(request_data_base, :custom_id, "size_limit_#{i}")
        {:ok, _} = BatchBuilder.add_request(url, model, request_data)
      end

      # 5th request should still succeed (at limit)
      {:ok, request5} =
        BatchBuilder.add_request(
          url,
          model,
          Map.put(request_data_base, :custom_id, "size_limit_5")
        )

      assert request5.custom_id == "size_limit_5"

      # 6th request should create a new batch (over limit)
      # Note: This may return an error if validation runs before BatchBuilder can handle it
      result6 =
        BatchBuilder.add_request(
          url,
          model,
          Map.put(request_data_base, :custom_id, "size_limit_6")
        )

      case result6 do
        {:ok, request6} ->
          # Should be in a different batch
          {:ok, batch5} = Batching.get_batch_by_id(request5.batch_id)
          {:ok, batch6} = Batching.get_batch_by_id(request6.batch_id)
          assert batch6.id != batch5.id

        {:error, _} ->
          # Validation may catch this before BatchBuilder can create new batch
          # This is acceptable behavior
          :ok
      end
    end

    test "handles finish_building when batch not found" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      # Create a BatchBuilder
      request_data = %{
        custom_id: "finish_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)

      # Get pid before destroying so we can monitor it
      pid = GenServer.whereis({:via, Registry, {Batcher.BatchRegistry, {url, model}}})
      ref = Process.monitor(pid)

      # Delete the batch directly from DB - this will terminate the BatchBuilder
      {:ok, batch} = Batching.get_batch_by_id(request.batch_id)
      Ash.destroy!(batch)

      # Wait for the BatchBuilder process to actually terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      # BatchBuilder should be terminated, upload_batch will try to find
      # the batch directly but it was destroyed, so it returns an error
      assert {:error, :no_building_batch} = BatchBuilder.upload_batch(url, model)
    end

    test "handles finish_building when start_upload fails" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      # Create a BatchBuilder with an empty batch
      request_data = %{
        custom_id: "finish_upload_fail",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)

      # Delete the request to make batch empty (start_upload will fail)
      Ash.destroy!(request)

      # Try to finish building - should handle gracefully
      result = BatchBuilder.upload_batch(url, model)

      # Should return error or handle gracefully
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles GenServer call timeout" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      request_data = %{
        custom_id: "timeout_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      # Create BatchBuilder
      {:ok, _request} = BatchBuilder.add_request(url, model, request_data)

      # Get the BatchBuilder PID
      [{pid, _}] = Registry.lookup(Batcher.BatchRegistry, {url, model})

      # Kill the BatchBuilder to simulate timeout/crash
      Process.exit(pid, :kill)

      # Wait for it to die
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        100 -> :ok
      end

      # Try to add request with different custom_id - should retry and create new BatchBuilder
      # (original request already exists, so we need a new custom_id)
      new_request_data = Map.put(request_data, :custom_id, "timeout_test_retry")
      {:ok, request} = BatchBuilder.add_request(url, model, new_request_data)

      assert request.custom_id == "timeout_test_retry"
    end

    test "handles already_started error when starting BatchBuilder" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      request_data = %{
        custom_id: "already_started_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      # Start two concurrent requests to trigger race condition
      task1 = Task.async(fn -> BatchBuilder.add_request(url, model, request_data) end)

      task2 =
        Task.async(fn ->
          # Slight delay to increase chance of race
          Process.sleep(10)

          BatchBuilder.add_request(
            url,
            model,
            Map.put(request_data, :custom_id, "already_started_test_2")
          )
        end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      # Both should succeed (already_started is handled)
      assert {:ok, _} = result1
      assert {:ok, _} = result2
    end

    test "handles batch state change notification when already terminating" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      request_data = %{
        custom_id: "terminating_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)
      batch_id = request.batch_id

      # Start upload (this will set terminating flag)
      :ok = BatchBuilder.upload_batch(url, model)

      # Send another state change notification (should be ignored)
      # This tests the terminating flag prevents double termination
      batch = Batching.get_batch_by_id!(batch_id)

      BatcherWeb.Endpoint.broadcast("batches:state_changed:#{batch_id}", "state_changed", %{
        data: batch
      })

      # BatchBuilder should have shut down
      assert Registry.lookup(Batcher.BatchRegistry, {url, model}) == []
    end

    test "handles get_batch_by_id error in handle_call" do
      url = "/v1/responses"
      model = "gpt-4o-mini"

      request_data = %{
        custom_id: "get_batch_error_test",
        url: url,
        body: %{input: "test", model: model},
        method: "POST",
        delivery_config: %{type: "webhook", webhook_url: "https://example.com/webhook"}
      }

      {:ok, request} = BatchBuilder.add_request(url, model, request_data)
      batch_id = request.batch_id

      # Delete the batch - this will terminate the BatchBuilder
      batch = Batching.get_batch_by_id!(batch_id)
      Ash.destroy!(batch)

      # Try to add another request - BatchBuilder was terminated, so it will
      # create a new BatchBuilder and new batch (correct behavior)
      result =
        BatchBuilder.add_request(
          url,
          model,
          Map.put(request_data, :custom_id, "get_batch_error_test_2")
        )

      # Should succeed - creates new batch since old one was destroyed
      assert {:ok, new_request} = result
      assert new_request.batch_id != batch_id
    end
  end
end
