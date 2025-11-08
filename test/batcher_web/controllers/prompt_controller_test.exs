defmodule BatcherWeb.PromptControllerTest do
  use BatcherWeb.ConnCase, async: false

  alias Batcher.{Batching, BatchRegistry}

  setup do
    # Clean up any existing BatchBuilders
    Registry.select(BatchRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok
  end

  describe "POST /api/prompt - webhook delivery" do
    test "creates prompt with webhook delivery", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "test-#{Ecto.UUID.generate()}",
        "max_output_tokens" => 500,
        "temperature" => 0.7,
        "input" => [
          %{"role" => "developer", "content" => "You are a helpful assistant"},
          %{"role" => "user", "content" => "Hello!"}
        ],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "https://api.example.com/webhook?auth=secret"
        }
      }

      conn = post(conn, ~p"/api/prompt", params)

      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)
      assert custom_id == params["custom_id"]

      # Verify prompt was created in database
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == custom_id))

      assert prompt != nil
      assert prompt.delivery_type == :webhook
      assert prompt.webhook_url == "https://api.example.com/webhook?auth=secret"
      assert prompt.state == :pending
    end

    test "assigns prompt to correct batch", %{conn: conn} do
      model = "gpt-4o-mini"
      endpoint = "/v1/responses"

      params = %{
        "model" => model,
        "endpoint" => endpoint,
        "custom_id" => "batch-test-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/prompt", params)

      assert %{"status" => "accepted"} = json_response(conn, 202)

      # Verify batch was created
      {:ok, batch} = Batching.find_draft_batch(model, endpoint)
      assert batch.model == model
      assert batch.endpoint == endpoint
      assert batch.state == :draft

      # Verify prompt belongs to batch
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == params["custom_id"]))
      assert prompt.batch_id == batch.id
    end

    test "reuses existing draft batch", %{conn: conn} do
      model = "gpt-4o-mini"
      endpoint = "/v1/responses"

      # Create two prompts
      params1 = %{
        "model" => model,
        "endpoint" => endpoint,
        "custom_id" => "reuse-1-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "First"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      params2 = %{
        "model" => model,
        "endpoint" => endpoint,
        "custom_id" => "reuse-2-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Second"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn1 = post(conn, ~p"/api/prompt", params1)
      conn2 = post(conn, ~p"/api/prompt", params2)

      assert %{"status" => "accepted"} = json_response(conn1, 202)
      assert %{"status" => "accepted"} = json_response(conn2, 202)

      # Get prompts
      {:ok, prompts} = Batching.get_prompts()
      prompt1 = Enum.find(prompts, &(&1.custom_id == params1["custom_id"]))
      prompt2 = Enum.find(prompts, &(&1.custom_id == params2["custom_id"]))

      # Both should be in the same batch
      assert prompt1.batch_id == prompt2.batch_id
    end
  end

  describe "POST /api/prompt - RabbitMQ delivery" do
    test "creates prompt with RabbitMQ delivery", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "rabbitmq-test-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "rabbitmq",
          "rabbitmq_queue" => "results_queue"
        }
      }

      conn = post(conn, ~p"/api/prompt", params)

      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)

      # Verify prompt
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == custom_id))

      assert prompt.delivery_type == :rabbitmq
      assert prompt.rabbitmq_queue == "results_queue"
      assert prompt.webhook_url == nil
    end
  end

  describe "POST /api/prompt - validation errors" do
    test "rejects duplicate custom_id", %{conn: conn} do
      custom_id = "duplicate-#{Ecto.UUID.generate()}"

      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => custom_id,
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      # First request succeeds
      conn1 = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn1, 202)

      # Second request with same custom_id fails
      conn2 = post(conn, ~p"/api/prompt", params)
      assert %{"error" => error} = json_response(conn2, 422)
      assert error =~ "custom_id"
    end

    test "rejects invalid endpoint", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/invalid/endpoint",
        "custom_id" => "invalid-endpoint-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "https://example.com/webhook"
        }
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => _error} = json_response(conn, 422)
    end

    test "rejects webhook delivery without webhook_url", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "missing-url-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook"
          # webhook_url is missing
        }
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "webhook_url"
    end

    test "rejects RabbitMQ delivery without rabbitmq_queue", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "missing-queue-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "rabbitmq"
          # rabbitmq_queue is missing
        }
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "rabbitmq_queue"
    end

    test "rejects invalid webhook_url format", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "invalid-url-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => "not-a-valid-url"
        }
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => _error} = json_response(conn, 422)
    end

    test "rejects missing required fields", %{conn: conn} do
      # Missing model
      params = %{
        "endpoint" => "/v1/responses",
        "custom_id" => "missing-model-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => _error} = json_response(conn, 400)
    end

    test "rejects missing custom_id", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        # custom_id is missing
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => _error} = json_response(conn, 400)
    end

    test "rejects missing input", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "missing-input-#{Ecto.UUID.generate()}",
        # input is missing
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"error" => _error} = json_response(conn, 400)
    end
  end

  describe "POST /api/prompt - different endpoints" do
    test "accepts /v1/responses endpoint", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "responses-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "accepts /v1/embeddings endpoint", %{conn: conn} do
      params = %{
        "model" => "text-embedding-3-small",
        "endpoint" => "/v1/embeddings",
        "custom_id" => "embeddings-#{Ecto.UUID.generate()}",
        "input" => "Text to embed",
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end
  end

  describe "POST /api/prompt - request payload handling" do
    test "preserves complex request payload", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "complex-#{Ecto.UUID.generate()}",
        "max_output_tokens" => 1000,
        "temperature" => 0.8,
        "top_p" => 0.9,
        "input" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "Hello"}
        ],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)

      # Verify payload was stored correctly
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == custom_id))

      assert prompt.request_payload["max_output_tokens"] == 1000
      assert prompt.request_payload["temperature"] == 0.8
      assert prompt.request_payload["top_p"] == 0.9
      assert length(prompt.request_payload["input"]) == 2
    end

    test "handles minimal request payload", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "minimal-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end
  end

  describe "POST /api/prompt - optional tag" do
    test "accepts prompt with tag", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "tagged-#{Ecto.UUID.generate()}",
        "tag" => "production-batch-2025",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)

      # Verify tag was stored
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == custom_id))
      assert prompt.tag == "production-batch-2025"
    end

    test "accepts prompt without tag", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "untagged-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end
  end

  describe "POST /api/prompt - concurrent requests" do
    test "handles concurrent requests for same batch", %{conn: conn} do
      model = "gpt-4o-mini"
      endpoint = "/v1/responses"

      # Send 10 concurrent requests
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            params = %{
              "model" => model,
              "endpoint" => endpoint,
              "custom_id" => "concurrent-#{i}-#{Ecto.UUID.generate()}",
              "input" => [%{"role" => "user", "content" => "Test #{i}"}],
              "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
            }

            post(conn, ~p"/api/prompt", params)
            |> json_response(202)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # All should succeed
      assert Enum.all?(results, fn result ->
               result["status"] == "accepted"
             end)

      # All should be in the same batch
      {:ok, batch} = Batching.find_draft_batch(model, endpoint)
      {:ok, batch_with_prompts} = Batching.get_batch_by_id(batch.id, load: [:prompts])

      assert length(batch_with_prompts.prompts) == 10
    end
  end

  describe "POST /api/prompt - edge cases" do
    test "handles very long custom_id", %{conn: conn} do
      long_id = String.duplicate("a", 500)

      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => long_id,
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)
      assert custom_id == long_id
    end

    test "handles special characters in custom_id", %{conn: conn} do
      special_id = "test-!@#$%_id-123"

      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => special_id,
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "handles webhook URL with query parameters", %{conn: conn} do
      url_with_params = "https://example.com/webhook?auth=secret&id=123&foo=bar"

      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "url-params-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{
          "type" => "webhook",
          "webhook_url" => url_with_params
        }
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted", "custom_id" => custom_id} = json_response(conn, 202)

      # Verify URL was stored correctly
      {:ok, prompts} = Batching.get_prompts()
      prompt = Enum.find(prompts, &(&1.custom_id == custom_id))
      assert prompt.webhook_url == url_with_params
    end

    test "handles large request payload", %{conn: conn} do
      # Create a large input array
      large_input =
        for i <- 1..100 do
          %{"role" => "user", "content" => "Message #{i}: #{String.duplicate("test ", 50)}"}
        end

      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "large-payload-#{Ecto.UUID.generate()}",
        "input" => large_input,
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "handles empty input array", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "empty-input-#{Ecto.UUID.generate()}",
        "input" => [],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      # This should succeed - validation of empty input happens at OpenAI level
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end
  end

  describe "POST /api/prompt - different models" do
    test "accepts gpt-4o-mini model", %{conn: conn} do
      params = %{
        "model" => "gpt-4o-mini",
        "endpoint" => "/v1/responses",
        "custom_id" => "gpt4o-mini-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "accepts gpt-4o model", %{conn: conn} do
      params = %{
        "model" => "gpt-4o",
        "endpoint" => "/v1/responses",
        "custom_id" => "gpt4o-#{Ecto.UUID.generate()}",
        "input" => [%{"role" => "user", "content" => "Test"}],
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "accepts text-embedding-3-small model", %{conn: conn} do
      params = %{
        "model" => "text-embedding-3-small",
        "endpoint" => "/v1/embeddings",
        "custom_id" => "embedding-#{Ecto.UUID.generate()}",
        "input" => "Text to embed",
        "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com/webhook"}
      }

      conn = post(conn, ~p"/api/prompt", params)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end
  end
end
