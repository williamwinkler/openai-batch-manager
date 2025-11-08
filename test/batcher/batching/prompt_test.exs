defmodule Batcher.Batching.PromptTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  import Batcher.BatchingFixtures

  describe "create_prompt/1" do
    test "creates a prompt with webhook delivery" do
      prompt = webhook_prompt_fixture(
        custom_id: "test-prompt-1",
        request_payload: %{
          "input" => [%{"role" => "user", "content" => "Hello"}],
          "max_output_tokens" => 100
        }
      )

      assert prompt.custom_id == "test-prompt-1"
      assert prompt.state == :pending
      assert prompt.delivery_type == :webhook
      assert String.starts_with?(prompt.webhook_url, "https://example.com/webhook")
      assert is_nil(prompt.rabbitmq_queue)
      assert is_integer(prompt.batch_id)
    end

    test "creates a prompt with RabbitMQ delivery" do
      prompt = rabbitmq_prompt_fixture(
        custom_id: "test-prompt-2",
        request_payload: %{
          "input" => [%{"role" => "user", "content" => "Hello"}]
        }
      )

      assert prompt.delivery_type == :rabbitmq
      assert prompt.rabbitmq_queue == "results_queue"
      assert is_nil(prompt.webhook_url)
    end

    test "creates prompt with initial state transition record" do
      prompt = prompt_fixture(custom_id: "test-prompt-3")

      # Load transitions
      {:ok, prompt_with_transitions} = Batching.get_prompt_by_id(prompt.id, load: [:transitions])

      assert length(prompt_with_transitions.transitions) == 1
      transition = hd(prompt_with_transitions.transitions)
      assert is_nil(transition.from)
      assert transition.to == :pending
    end

    test "creates prompt with optional tag" do
      prompt = prompt_fixture(
        custom_id: "test-prompt-4",
        tag: "production-batch"
      )

      assert prompt.tag == "production-batch"
    end
  end

  describe "delivery configuration validation" do
    setup do
      batch = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      %{batch: batch}
    end

    test "requires webhook_url for webhook delivery", %{batch: batch} do
      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "missing-webhook-url",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook
          # webhook_url is missing
        })

      assert error != nil
    end

    test "requires rabbitmq_queue for rabbitmq delivery", %{batch: batch} do
      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "missing-queue",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :rabbitmq
          # rabbitmq_queue is missing
        })

      assert error != nil
    end

    test "webhook delivery requires rabbitmq_queue to be nil", %{batch: batch} do
      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "both-delivery",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",
          rabbitmq_queue: "queue_name"
        })

      assert error != nil
    end

    test "rabbitmq delivery requires webhook_url to be nil", %{batch: batch} do
      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "both-delivery-2",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :rabbitmq,
          rabbitmq_queue: "queue_name",
          webhook_url: "https://example.com/webhook"
        })

      assert error != nil
    end

    test "validates webhook_url format", %{batch: batch} do
      # Valid HTTP URL
      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "http-url",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "http://example.com/webhook"
        })

      # Valid HTTPS URL
      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "https-url",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook?auth=secret"
        })
    end

    test "rejects invalid webhook_url format", %{batch: batch} do
      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "invalid-url",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "not-a-url"
        })
    end
  end

  describe "endpoint validation" do
    setup do
      batch = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      %{batch: batch}
    end

    test "accepts valid /v1/responses endpoint", %{batch: batch} do
      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "valid-endpoint-1",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      assert prompt.endpoint == "/v1/responses"
    end

    test "accepts valid /v1/embeddings endpoint" do
      batch = batch_fixture(model: "text-embedding-3-small", endpoint: "/v1/embeddings")

      {:ok, prompt} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "valid-endpoint-2",
          endpoint: "/v1/embeddings",
          model: "text-embedding-3-small",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      assert prompt.endpoint == "/v1/embeddings"
    end

    test "rejects invalid endpoint", %{batch: batch} do
      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "invalid-endpoint",
          endpoint: "/invalid/endpoint",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })
    end
  end

  describe "custom_id uniqueness" do
    setup do
      batch = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      %{batch: batch}
    end

    test "allows unique custom_ids within same batch", %{batch: batch} do
      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "unique-1",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "unique-2",
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 2},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })
    end

    test "rejects duplicate custom_id globally (across batches)" do
      batch1 = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      batch2 = batch_fixture(model: "gpt-4o", endpoint: "/v1/responses")

      custom_id = "duplicate-test-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Batching.create_prompt(%{
          batch_id: batch1.id,
          custom_id: custom_id,
          endpoint: "/v1/responses",
          model: "gpt-4o-mini",
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      {:error, error} =
        Batching.create_prompt(%{
          batch_id: batch2.id,
          custom_id: custom_id,
          endpoint: "/v1/responses",
          model: "gpt-4o",
          request_payload: %{"test" => 2},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })

      assert error != nil
    end
  end

  describe "prompt state transitions - happy path" do
    setup do
      prompt = prompt_fixture(custom_id: "transition-test")
      %{prompt: prompt}
    end

    test "follows complete workflow from pending to delivered", %{prompt: prompt} do
      assert prompt.state == :pending

      {:ok, prompt} = Batching.prompt_begin_processing(prompt)
      assert prompt.state == :processing

      {:ok, prompt} = Batching.prompt_complete_processing(prompt)
      assert prompt.state == :processed

      {:ok, prompt} = Batching.prompt_begin_delivery(prompt)
      assert prompt.state == :delivering

      {:ok, prompt} = Batching.prompt_complete_delivery(prompt)
      assert prompt.state == :delivered
    end

    test "creates transition record for each state change", %{prompt: prompt} do
      {:ok, prompt} = Batching.prompt_begin_processing(prompt)
      {:ok, prompt} = Batching.prompt_complete_processing(prompt)
      {:ok, prompt} = Batching.prompt_begin_delivery(prompt)
      {:ok, prompt} = Batching.prompt_complete_delivery(prompt)

      # Load all transitions
      {:ok, prompt_with_transitions} =
        Batching.get_prompt_by_id(prompt.id, load: [:transitions])

      # Should have 5 transitions (initial + 4 state changes)
      assert length(prompt_with_transitions.transitions) == 5

      # Verify the sequence
      states = Enum.map(prompt_with_transitions.transitions, & &1.to)
      assert states == [:pending, :processing, :processed, :delivering, :delivered]
    end
  end

  describe "failure transitions" do
    test "allows failure from pending state" do
      prompt = prompt_fixture()

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: "Test error"})

      assert failed.state == :failed
      assert failed.error_msg == "Test error"
    end

    test "allows failure from processing state" do
      prompt = prompt_fixture(state: :processing)

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: "Processing failed"})

      assert failed.state == :failed
    end

    test "allows failure from processed state" do
      prompt = prompt_fixture(state: :processed)

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: "Validation failed"})

      assert failed.state == :failed
    end

    test "allows failure from delivering state" do
      prompt = prompt_fixture(state: :delivering)

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: "Delivery failed"})

      assert failed.state == :failed
    end

    test "doesn't allow failure from delivered state" do
      prompt = prompt_fixture(state: :delivered)

      {:error, _} = Batching.prompt_mark_failed(prompt, %{error_msg: "Test"})
    end
  end

  describe "expiration transitions" do
    test "allows expiration from pending state" do
      prompt = prompt_fixture()

      {:ok, expired} = Batching.prompt_mark_expired(prompt, %{error_msg: "Expired"})

      assert expired.state == :expired
    end

    test "allows expiration from processing state" do
      prompt = prompt_fixture(state: :processing)

      {:ok, expired} = Batching.prompt_mark_expired(prompt, %{error_msg: "Timeout"})

      assert expired.state == :expired
    end

    test "doesn't allow expiration from processed state" do
      prompt = prompt_fixture(state: :processed)

      {:error, _} = Batching.prompt_mark_expired(prompt, %{error_msg: "Test"})
    end
  end

  describe "cancellation transitions" do
    test "allows cancellation from pending state" do
      prompt = prompt_fixture()

      {:ok, cancelled} = Batching.prompt_cancel(prompt)

      assert cancelled.state == :cancelled
    end

    test "doesn't allow cancellation from processing state" do
      prompt = prompt_fixture(state: :processing)

      {:error, _} = Batching.prompt_cancel(prompt)
    end
  end

  describe "get_prompt_by_id/2" do
    test "retrieves prompt by id" do
      prompt = prompt_fixture(custom_id: "get-test")

      {:ok, retrieved} = Batching.get_prompt_by_id(prompt.id)

      assert retrieved.id == prompt.id
      assert retrieved.custom_id == "get-test"
    end

    test "loads batch relationship when requested" do
      prompt = prompt_fixture()

      {:ok, prompt_with_batch} = Batching.get_prompt_by_id(prompt.id, load: [:batch])

      refute is_nil(prompt_with_batch.batch)
      assert prompt_with_batch.batch.id == prompt.batch_id
    end

    test "loads transitions relationship when requested" do
      prompt = prompt_fixture()
      {:ok, prompt} = Batching.prompt_begin_processing(prompt)

      {:ok, prompt_with_transitions} = Batching.get_prompt_by_id(prompt.id, load: [:transitions])

      assert length(prompt_with_transitions.transitions) >= 2
    end

    test "returns error for nonexistent prompt" do
      assert {:error, _} = Batching.get_prompt_by_id(999_999)
    end
  end

  describe "edge cases" do
    test "handles empty request_payload" do
      prompt = prompt_fixture(
        custom_id: "empty-payload",
        request_payload: %{}
      )

      assert prompt.request_payload == %{}
    end

    test "handles complex request_payload" do
      complex_payload = %{
        "input" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_output_tokens" => 1000,
        "temperature" => 0.7,
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ]
      }

      prompt = prompt_fixture(
        custom_id: "complex-payload",
        request_payload: complex_payload
      )

      assert prompt.request_payload == complex_payload
    end

    test "handles very long custom_id" do
      long_id = String.duplicate("a", 500)

      prompt = prompt_fixture(custom_id: long_id)

      assert prompt.custom_id == long_id
    end

    test "handles special characters in custom_id" do
      special_id = "test-!@#$%_id-123"

      prompt = prompt_fixture(custom_id: special_id)

      assert prompt.custom_id == special_id
    end

    test "handles webhook URL with query parameters" do
      url_with_params = "https://example.com/webhook?auth=secret&id=123"

      prompt = webhook_prompt_fixture(
        custom_id: "url-params-test",
        webhook_url: url_with_params
      )

      assert prompt.webhook_url == url_with_params
    end

    test "handles empty error_msg on failure" do
      prompt = prompt_fixture(custom_id: "empty-error-test")

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: ""})

      assert failed.state == :failed
      # Empty string is stored as nil
      assert is_nil(failed.error_msg) or failed.error_msg == ""
    end

    test "handles very long error_msg on failure" do
      prompt = prompt_fixture(custom_id: "long-error-test")
      long_error = String.duplicate("error ", 1000)

      {:ok, failed} = Batching.prompt_mark_failed(prompt, %{error_msg: long_error})

      assert failed.state == :failed
      # Error message may be truncated by database, so just check it starts with expected value
      assert String.starts_with?(failed.error_msg, "error error error")
      assert String.length(failed.error_msg) > 100
    end

    test "handles nil tag" do
      prompt = prompt_fixture(
        custom_id: "nil-tag-test",
        tag: nil
      )

      assert is_nil(prompt.tag)
    end
  end

  describe "batch relationship" do
    test "prompts are deleted when batch is deleted" do
      batch = batch_fixture()
      prompt = prompt_fixture(batch: batch, custom_id: "cascade-test")

      Batching.destroy_batch(batch)

      # Prompt should be deleted (cascade)
      assert {:error, _} = Batching.get_prompt_by_id(prompt.id)
    end

    test "can query prompts by batch" do
      {batch, prompts} = batch_with_prompts_fixture(
        prompt_count: 2,
        prompt_attrs: [
          [custom_id: "query-1"],
          [custom_id: "query-2"]
        ]
      )

      {:ok, batch_with_prompts} = Batching.get_batch_by_id(batch.id, load: [:prompts])

      assert length(batch_with_prompts.prompts) == 2
      assert Enum.map(prompts, & &1.id) |> Enum.sort() ==
             Enum.map(batch_with_prompts.prompts, & &1.id) |> Enum.sort()
    end
  end

  describe "URL validation edge cases" do
    test "accepts localhost webhook URL" do
      prompt = webhook_prompt_fixture(
        custom_id: "localhost-test",
        webhook_url: "http://localhost:4000/webhook"
      )

      assert prompt.webhook_url == "http://localhost:4000/webhook"
    end

    test "accepts IP address in webhook URL" do
      prompt = webhook_prompt_fixture(
        custom_id: "ip-test",
        webhook_url: "https://192.168.1.1/webhook"
      )

      assert prompt.webhook_url == "https://192.168.1.1/webhook"
    end

    test "rejects ftp:// scheme" do
      batch = batch_fixture()

      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "ftp-test",
          endpoint: batch.endpoint,
          model: batch.model,
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "ftp://example.com/webhook"
        })
    end

    test "rejects URL with no scheme" do
      batch = batch_fixture()

      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "no-scheme-test",
          endpoint: batch.endpoint,
          model: batch.model,
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "example.com/webhook"
        })
    end

    test "rejects URL with only scheme and no host" do
      batch = batch_fixture()

      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch.id,
          custom_id: "no-host-test",
          endpoint: batch.endpoint,
          model: batch.model,
          request_payload: %{"test" => 1},
          delivery_type: :webhook,
          webhook_url: "https://"
        })
    end

    test "handles webhook URL with encoded characters" do
      prompt = webhook_prompt_fixture(
        custom_id: "encoded-url-test",
        webhook_url: "https://example.com/webhook?token=abc%20def"
      )

      assert prompt.webhook_url == "https://example.com/webhook?token=abc%20def"
    end

    test "handles webhook URL with fragment" do
      prompt = webhook_prompt_fixture(
        custom_id: "fragment-url-test",
        webhook_url: "https://example.com/webhook#section"
      )

      assert prompt.webhook_url == "https://example.com/webhook#section"
    end

    test "handles webhook URL with port" do
      prompt = webhook_prompt_fixture(
        custom_id: "port-url-test",
        webhook_url: "https://example.com:8080/webhook"
      )

      assert prompt.webhook_url == "https://example.com:8080/webhook"
    end

    test "handles webhook URL with authentication" do
      prompt = webhook_prompt_fixture(
        custom_id: "auth-url-test",
        webhook_url: "https://user:pass@example.com/webhook"
      )

      assert prompt.webhook_url == "https://user:pass@example.com/webhook"
    end
  end

  describe "concurrent operations and race conditions" do
    test "prevents duplicate custom_id when created concurrently" do
      batch = batch_fixture()
      custom_id = "concurrent-test-#{Ecto.UUID.generate()}"

      tasks =
        1..5
        |> Enum.map(fn i ->
          Task.async(fn ->
            Batching.create_prompt(%{
              batch_id: batch.id,
              custom_id: custom_id,
              endpoint: batch.endpoint,
              model: batch.model,
              request_payload: %{"test" => i},
              delivery_type: :webhook,
              webhook_url: "https://example.com/webhook/#{i}"
            })
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # Only one should succeed
      successful = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
      assert successful == 1
    end

    test "handles concurrent state transitions safely" do
      prompt = prompt_fixture()

      # Try to transition to both processing and failed simultaneously
      task1 = Task.async(fn -> Batching.prompt_begin_processing(prompt) end)
      task2 = Task.async(fn -> Batching.prompt_mark_failed(prompt) end)

      _results = Task.await_many([task1, task2], 5000)

      # Both might succeed (since both transitions are valid from pending)
      # but we verify the final state is consistent
      {:ok, final_prompt} = Batching.get_prompt_by_id(prompt.id)
      assert final_prompt.state in [:processing, :failed]
    end
  end

  describe "unicode and special character handling" do
    test "handles unicode in custom_id" do
      prompt = prompt_fixture(custom_id: "test-日本語-🚀")

      assert prompt.custom_id == "test-日本語-🚀"
    end

    test "handles unicode in request_payload" do
      prompt = prompt_fixture(
        request_payload: %{
          "content" => "Hello 世界 🌍 مرحبا Привет",
          "emoji" => "🎉🚀✨"
        }
      )

      assert prompt.request_payload["content"] =~ "世界"
      assert prompt.request_payload["emoji"] =~ "🎉"
    end

    test "handles unicode in tag" do
      prompt = prompt_fixture(tag: "важный-тест-🔥")

      assert prompt.tag == "важный-тест-🔥"
    end

    test "handles unicode in error messages" do
      prompt = prompt_fixture()

      {:ok, failed} =
        Batching.prompt_mark_failed(prompt, %{
          error_msg: "エラー: 処理失敗 ❌"
        })

      assert failed.error_msg == "エラー: 処理失敗 ❌"
    end

    test "handles newlines in request_payload" do
      prompt = prompt_fixture(
        request_payload: %{
          "content" => "Line 1\nLine 2\nLine 3"
        }
      )

      assert prompt.request_payload["content"] =~ "\n"
    end

    test "handles tabs and special whitespace" do
      prompt = prompt_fixture(
        request_payload: %{
          "content" => "Tab\there\nSpace  here"
        }
      )

      assert prompt.request_payload["content"] =~ "\t"
    end
  end

  describe "rabbitmq queue name edge cases" do
    test "accepts queue name with dots" do
      prompt = rabbitmq_prompt_fixture(rabbitmq_queue: "results.queue.v1")

      assert prompt.rabbitmq_queue == "results.queue.v1"
    end

    test "accepts queue name with underscores" do
      prompt = rabbitmq_prompt_fixture(rabbitmq_queue: "results_queue_v1")

      assert prompt.rabbitmq_queue == "results_queue_v1"
    end

    test "accepts queue name with hyphens" do
      prompt = rabbitmq_prompt_fixture(rabbitmq_queue: "results-queue-v1")

      assert prompt.rabbitmq_queue == "results-queue-v1"
    end

    test "accepts very long queue name" do
      long_queue = "queue_" <> String.duplicate("a", 200)
      prompt = rabbitmq_prompt_fixture(rabbitmq_queue: long_queue)

      assert prompt.rabbitmq_queue == long_queue
    end
  end

  describe "invalid state transitions" do
    test "cannot skip states in workflow" do
      prompt = prompt_fixture()

      # Try to skip from pending to delivered
      {:error, _} = Batching.prompt_complete_delivery(prompt)
    end

    test "cannot transition from terminal state failed" do
      prompt = prompt_fixture(state: :failed)

      # Cannot transition from failed to any other state
      {:error, _} = Batching.prompt_begin_processing(prompt)
      {:error, _} = Batching.prompt_cancel(prompt)
    end

    test "cannot transition from terminal state cancelled" do
      prompt = prompt_fixture(state: :cancelled)

      # Cannot transition from cancelled to any other state
      {:error, _} = Batching.prompt_begin_processing(prompt)
      {:error, _} = Batching.prompt_mark_failed(prompt)
    end

    test "cannot transition from terminal state expired" do
      prompt = prompt_fixture(state: :expired)

      # Cannot transition from expired to any other state
      {:error, _} = Batching.prompt_begin_processing(prompt)
      {:error, _} = Batching.prompt_mark_failed(prompt)
    end

    test "cannot transition from terminal state delivered" do
      prompt = prompt_fixture(state: :delivered)

      # Cannot transition from delivered
      {:error, _} = Batching.prompt_mark_failed(prompt)
      {:error, _} = Batching.prompt_cancel(prompt)
    end
  end

  describe "prompts across different batches" do
    test "prompts with same custom_id cannot exist across different batches" do
      batch1 = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      batch2 = batch_fixture(model: "gpt-4o", endpoint: "/v1/responses")

      custom_id = "cross-batch-#{Ecto.UUID.generate()}"

      _prompt1 = prompt_fixture(batch: batch1, custom_id: custom_id)

      # Try to create with same custom_id in different batch
      {:error, _} =
        Batching.create_prompt(%{
          batch_id: batch2.id,
          custom_id: custom_id,
          endpoint: batch2.endpoint,
          model: batch2.model,
          request_payload: %{"test" => 2},
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook"
        })
    end

    test "different batches can have prompts with different custom_ids" do
      batch1 = batch_fixture(model: "gpt-4o-mini", endpoint: "/v1/responses")
      batch2 = batch_fixture(model: "gpt-4o", endpoint: "/v1/responses")

      prompt1 = prompt_fixture(batch: batch1, custom_id: "batch1-prompt")
      prompt2 = prompt_fixture(batch: batch2, custom_id: "batch2-prompt")

      assert prompt1.batch_id != prompt2.batch_id
      assert prompt1.custom_id != prompt2.custom_id
    end
  end
end
