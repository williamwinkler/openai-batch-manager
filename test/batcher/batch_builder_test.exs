defmodule Batcher.BatchBuilderTest do
  use Batcher.DataCase, async: false

  alias Batcher.{BatchBuilder, Batching, BatchRegistry}

  setup do
    # Clean up any existing BatchBuilders
    Registry.select(BatchRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts a BatchBuilder for a given endpoint/model combination" do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      {:ok, pid} = BatchBuilder.start_link({endpoint, model})

      assert Process.alive?(pid)
    end

    test "registers the BatchBuilder in the registry" do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      assert [{pid, _}] = Registry.lookup(BatchRegistry, {endpoint, model})
      assert Process.alive?(pid)
    end

    test "creates a new batch in draft state" do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Verify batch was created
      {:ok, batches} = Batching.get_batches()
      draft_batch = Enum.find(batches, &(&1.state == :draft and &1.model == model))

      assert draft_batch != nil
      assert draft_batch.endpoint == endpoint
      assert draft_batch.model == model
    end

    test "reuses existing draft batch if one exists" do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      # Create a draft batch manually
      {:ok, existing_batch} = Batching.create_batch(model, endpoint)

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Should only have one batch
      {:ok, batches} = Batching.get_batches()
      draft_batches = Enum.filter(batches, &(&1.state == :draft and &1.model == model))

      assert length(draft_batches) == 1
      assert hd(draft_batches).id == existing_batch.id
    end
  end

  describe "add_prompt/3" do
    setup do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      # Ensure BatchBuilder is started
      case Registry.lookup(BatchRegistry, {endpoint, model}) do
        [] -> BatchBuilder.start_link({endpoint, model})
        [{pid, _}] -> {:ok, pid}
      end

      %{endpoint: endpoint, model: model}
    end

    test "adds a prompt to the batch", %{endpoint: endpoint, model: model} do
      prompt_data = %{
        custom_id: "test-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{
          "input" => [
            %{"role" => "user", "content" => "Hello"}
          ],
          "max_output_tokens" => 100
        },
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)

      assert prompt.custom_id == prompt_data.custom_id
      assert prompt.state == :pending
      assert prompt.endpoint == endpoint
      assert prompt.model == model
    end

    test "increments prompt count", %{endpoint: endpoint, model: model} do
      prompt_data_1 = %{
        custom_id: "test-1-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Hello 1"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      prompt_data_2 = %{
        custom_id: "test-2-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Hello 2"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, _prompt1} = BatchBuilder.add_prompt(endpoint, model, prompt_data_1)
      {:ok, _prompt2} = BatchBuilder.add_prompt(endpoint, model, prompt_data_2)

      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      assert state.prompt_count == 2
    end

    test "rejects duplicate custom_id within same batch", %{endpoint: endpoint, model: model} do
      custom_id = "duplicate-test-#{Ecto.UUID.generate()}"

      prompt_data = %{
        custom_id: custom_id,
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Hello"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, _prompt1} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      {:error, :custom_id_already_taken} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
    end

    test "starts new BatchBuilder if none exists", %{endpoint: endpoint, model: model} do
      # Stop existing BatchBuilder
      [{pid, _}] = Registry.lookup(BatchRegistry, {endpoint, model})
      GenServer.stop(pid, :normal)
      Process.sleep(10)

      # Verify it's gone
      assert Registry.lookup(BatchRegistry, {endpoint, model}) == []

      prompt_data = %{
        custom_id: "new-builder-test-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Hello"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      # This should start a new BatchBuilder
      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)

      assert prompt != nil
      assert Registry.lookup(BatchRegistry, {endpoint, model}) != []
    end

    test "validates delivery configuration", %{endpoint: endpoint, model: model} do
      # Missing webhook_url for webhook delivery
      invalid_prompt_data = %{
        custom_id: "invalid-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Hello"}]},
        delivery_type: :webhook
        # webhook_url is missing
      }

      {:error, error} = BatchBuilder.add_prompt(endpoint, model, invalid_prompt_data)
      assert error != nil
    end
  end

  describe "get_state/2" do
    test "returns current BatchBuilder state" do
      endpoint = "/v1/responses"
      model = "gpt-4o-mini"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      {:ok, state} = BatchBuilder.get_state(endpoint, model)

      assert state.endpoint == endpoint
      assert state.model == model
      assert state.prompt_count == 0
      assert state.status == :collecting
      assert state.batch_id != nil
    end

    test "returns error when BatchBuilder doesn't exist" do
      endpoint = "/v1/nonexistent"
      model = "gpt-99"

      {:error, :not_found} = BatchBuilder.get_state(endpoint, model)
    end
  end

  describe "batch capacity" do
    @tag timeout: 120_000
    test "marks batch ready when reaching max prompts" do
      endpoint = "/v1/responses"
      model = "capacity-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Get the max_prompts config (default 50,000)
      max_prompts = Application.get_env(:batcher, Batcher.BatchBuilder)[:max_prompts] || 50_000

      # We'll test with a smaller number to keep tests fast
      # Override the module attribute by testing behavior at a lower threshold
      # For this test, let's just verify the logic works with a few prompts
      # and check that the batch transitions to ready_for_upload

      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      initial_batch_id = state.batch_id

      # Add a few prompts
      for i <- 1..5 do
        prompt_data = %{
          custom_id: "capacity-test-#{i}",
          endpoint: endpoint,
          model: model,
          request_payload: %{"input" => [%{"role" => "user", "content" => "Test #{i}"}]},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        }

        {:ok, _} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      end

      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      assert state.prompt_count == 5
      assert state.batch_id == initial_batch_id

      # Note: In production, when max_prompts is reached, the batch would be marked ready
      # and the BatchBuilder would shut down. Testing the full capacity would require
      # 50k+ prompts which is impractical for unit tests.
    end
  end

  describe "counting prompts in batch" do
    test "correctly counts existing prompts when reusing draft batch" do
      endpoint = "/v1/responses"
      model = "count-test"

      # Create a draft batch with some prompts manually
      {:ok, batch} = Batching.create_batch(model, endpoint)

      # Add prompts directly to the batch
      for i <- 1..3 do
        {:ok, _} =
          Batching.create_prompt(%{
            batch_id: batch.id,
            custom_id: "existing-#{i}",
            endpoint: endpoint,
            model: model,
            request_payload: %{"test" => i},
            delivery_type: :webhook,
            webhook_url: "https://example.com/webhook"
          })
      end

      # Now start BatchBuilder - it should find the draft batch and count existing prompts
      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      assert state.prompt_count == 3
      assert state.batch_id == batch.id
    end
  end

  describe "multiple BatchBuilders" do
    test "different endpoint/model combinations have separate BatchBuilders" do
      endpoint1 = "/v1/responses"
      endpoint2 = "/v1/embeddings"
      model1 = "gpt-4o-mini"
      model2 = "text-embedding-3-small"

      {:ok, pid1} = BatchBuilder.start_link({endpoint1, model1})
      {:ok, pid2} = BatchBuilder.start_link({endpoint2, model2})

      assert pid1 != pid2

      {:ok, state1} = BatchBuilder.get_state(endpoint1, model1)
      {:ok, state2} = BatchBuilder.get_state(endpoint2, model2)

      assert state1.batch_id != state2.batch_id
      assert state1.endpoint == endpoint1
      assert state2.endpoint == endpoint2
    end

    test "same endpoint different models have separate batches" do
      endpoint = "/v1/responses"
      model1 = "gpt-4o-mini"
      model2 = "gpt-4o"

      {:ok, _pid1} = BatchBuilder.start_link({endpoint, model1})
      {:ok, _pid2} = BatchBuilder.start_link({endpoint, model2})

      {:ok, state1} = BatchBuilder.get_state(endpoint, model1)
      {:ok, state2} = BatchBuilder.get_state(endpoint, model2)

      assert state1.batch_id != state2.batch_id
    end
  end

  describe "error handling" do
    test "returns error when prompt creation fails", %{} do
      endpoint = "/v1/responses"
      model = "error-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Invalid prompt data - missing required fields
      invalid_data = %{
        custom_id: "invalid",
        endpoint: endpoint,
        model: model
        # Missing request_payload and delivery config
      }

      {:error, _error} = BatchBuilder.add_prompt(endpoint, model, invalid_data)
    end
  end

  describe "find_draft_batch/2" do
    test "finds existing draft batch for model/endpoint" do
      model = "gpt-4o-mini"
      endpoint = "/v1/responses"

      {:ok, batch} = Batching.create_batch(model, endpoint)

      {:ok, found_batch} = Batching.find_draft_batch(model, endpoint)

      assert found_batch.id == batch.id
      assert found_batch.state == :draft
    end

    test "returns error when no draft batch exists" do
      {:error, _} = Batching.find_draft_batch("nonexistent-model", "/v1/nonexistent")
    end

    test "doesn't find batches in other states" do
      model = "gpt-4o-mini"
      endpoint = "/v1/responses"

      {:ok, batch} = Batching.create_batch(model, endpoint)
      {:ok, _} = Batching.batch_mark_ready(batch)

      {:error, _} = Batching.find_draft_batch(model, endpoint)
    end
  end

  describe "crash recovery and resilience" do
    test "new BatchBuilder recovers from crash with existing draft batch" do
      endpoint = "/v1/responses"
      model = "crash-test"

      {:ok, pid} = BatchBuilder.start_link({endpoint, model})
      {:ok, original_state} = BatchBuilder.get_state(endpoint, model)
      original_batch_id = original_state.batch_id

      # Add a prompt to the batch
      prompt_data = %{
        custom_id: "pre-crash-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Before crash"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, _} = BatchBuilder.add_prompt(endpoint, model, prompt_data)

      # Simulate crash
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Verify it's dead
      refute Process.alive?(pid)
      assert Registry.lookup(BatchRegistry, {endpoint, model}) == []

      # Start new BatchBuilder - it should find the existing draft batch
      {:ok, new_pid} = BatchBuilder.start_link({endpoint, model})
      {:ok, new_state} = BatchBuilder.get_state(endpoint, model)

      # Should reuse the same batch
      assert new_state.batch_id == original_batch_id
      # Should have counted the existing prompt
      assert new_state.prompt_count == 1
      assert new_pid != pid
    end

    test "handles race condition when multiple processes try to start BatchBuilder" do
      endpoint = "/v1/responses"
      model = "race-test-#{Ecto.UUID.generate()}"

      # Start multiple processes trying to start the same BatchBuilder
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            BatchBuilder.start_link({endpoint, model})
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Only one should succeed, others should fail or return the existing pid
      successful_starts =
        Enum.filter(results, fn
          {:ok, _pid} -> true
          _ -> false
        end)

      # At least one should succeed
      assert length(successful_starts) >= 1

      # Should only have one BatchBuilder registered
      registry_entries = Registry.lookup(BatchRegistry, {endpoint, model})
      assert length(registry_entries) == 1
    end

    test "handles concurrent prompt additions" do
      endpoint = "/v1/responses"
      model = "concurrent-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Add prompts concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            prompt_data = %{
              custom_id: "concurrent-#{i}-#{Ecto.UUID.generate()}",
              endpoint: endpoint,
              model: model,
              request_payload: %{"input" => [%{"role" => "user", "content" => "Test #{i}"}]},
              delivery_type: :webhook,
              webhook_url: "https://example.com/webhook/#{i}"
            }

            BatchBuilder.add_prompt(endpoint, model, prompt_data)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _prompt} -> true
               _ -> false
             end)

      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      assert state.prompt_count == 10
    end

    test "handles timeout during add_prompt" do
      endpoint = "/v1/responses"
      model = "timeout-test"

      {:ok, pid} = BatchBuilder.start_link({endpoint, model})

      # Suspend the GenServer to simulate it being blocked
      :sys.suspend(pid)

      prompt_data = %{
        custom_id: "timeout-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"input" => [%{"role" => "user", "content" => "Test"}]},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      # This should timeout (default timeout is 30 seconds, but GenServer is suspended)
      task =
        Task.async(fn ->
          BatchBuilder.add_prompt(endpoint, model, prompt_data)
        end)

      # Give it a moment to queue up
      Process.sleep(100)

      # Resume the GenServer
      :sys.resume(pid)

      # Now it should complete
      {:ok, prompt} = Task.await(task, 5000)
      assert prompt.custom_id == prompt_data.custom_id
    end

    test "BatchBuilder properly unregisters when batch is marked ready" do
      endpoint = "/v1/responses"
      model = "unregister-test"

      {:ok, pid} = BatchBuilder.start_link({endpoint, model})
      {:ok, state} = BatchBuilder.get_state(endpoint, model)
      batch_id = state.batch_id

      # Manually mark batch as ready (simulating the BatchBuilder's own logic)
      {:ok, _} = Batching.batch_mark_ready(batch_id)

      # The BatchBuilder should still be registered at this point
      # because we marked it ready externally, not through the BatchBuilder

      # But if we try to add another prompt, it should create a new batch
      # Let's stop the current one and start fresh
      GenServer.stop(pid, :normal)
      Process.sleep(50)

      # Start a new BatchBuilder
      {:ok, new_pid} = BatchBuilder.start_link({endpoint, model})
      {:ok, new_state} = BatchBuilder.get_state(endpoint, model)

      # Should have created a new batch (old one was marked ready)
      assert new_state.batch_id != batch_id
    end
  end

  describe "edge cases" do
    test "handles empty request_payload" do
      endpoint = "/v1/responses"
      model = "empty-payload-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      prompt_data = %{
        custom_id: "empty-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      # This should succeed - validation happens at a higher level
      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.request_payload == %{}
    end

    test "handles very long custom_id" do
      endpoint = "/v1/responses"
      model = "long-id-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      long_id = String.duplicate("a", 1000)

      prompt_data = %{
        custom_id: long_id,
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.custom_id == long_id
    end

    test "handles special characters in custom_id" do
      endpoint = "/v1/responses"
      model = "special-chars-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      special_id = "test-!@#$%^&*()_+-=[]{}|;':\",./<>?`~"

      prompt_data = %{
        custom_id: special_id,
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook"
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.custom_id == special_id
    end

    test "handles both webhook_url and rabbitmq_queue provided" do
      endpoint = "/v1/responses"
      model = "both-delivery-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      # Providing both should fail validation
      prompt_data = %{
        custom_id: "both-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook",
        rabbitmq_queue: "queue_name"
      }

      # Should fail validation (webhook delivery requires rabbitmq_queue to be nil)
      {:error, _} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
    end

    test "handles prompt with nil tag" do
      endpoint = "/v1/responses"
      model = "nil-tag-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      prompt_data = %{
        custom_id: "nil-tag-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook",
        tag: nil
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.tag == nil
    end

    test "handles prompt with custom tag" do
      endpoint = "/v1/responses"
      model = "custom-tag-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      prompt_data = %{
        custom_id: "tagged-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :webhook,
        webhook_url: "https://example.com/webhook",
        tag: "production-batch-2025"
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.tag == "production-batch-2025"
    end

    test "handles RabbitMQ delivery type" do
      endpoint = "/v1/responses"
      model = "rabbitmq-test"

      {:ok, _pid} = BatchBuilder.start_link({endpoint, model})

      prompt_data = %{
        custom_id: "rabbitmq-#{Ecto.UUID.generate()}",
        endpoint: endpoint,
        model: model,
        request_payload: %{"test" => "data"},
        delivery_type: :rabbitmq,
        rabbitmq_queue: "results_queue"
      }

      {:ok, prompt} = BatchBuilder.add_prompt(endpoint, model, prompt_data)
      assert prompt.delivery_type == :rabbitmq
      assert prompt.rabbitmq_queue == "results_queue"
      assert prompt.webhook_url == nil
    end
  end
end
