# priv/scripts/all_endpoints.exs
#
# Sends 5 requests to each supported OpenAI Batch API endpoint:
# - /v1/responses
# - /v1/chat/completions
# - /v1/embeddings
#
# Run with: mix run priv/scripts/all_endpoints.exs

defmodule AllEndpointsScript do
  @webhook_url "https://webhook.site/737a3db4-1de7-429e-aae6-6239a3582fe9"
  @api_url "http://localhost:4000/api/requests"

  def run do
    IO.puts("Sending requests to all supported endpoints...")
    IO.puts("")

    send_responses_requests()
    send_chat_completions_requests()
    send_embeddings_requests()

    IO.puts("")
    IO.puts("Done! Sent 15 total requests (5 per endpoint)")
  end

  # /v1/responses - Responses API (modern)
  defp send_responses_requests do
    IO.puts("Sending 5 requests to /v1/responses...")

    prompts = [
      "Explain quantum computing in simple terms.",
      "What are the benefits of renewable energy?",
      "Describe the process of photosynthesis.",
      "What is machine learning and how does it work?",
      "Explain the theory of relativity."
    ]

    for prompt <- prompts do
      req = %{
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => prompt
        },
        "custom_id" => Ecto.UUID.generate(),
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => @webhook_url
        },
        "method" => "POST",
        "url" => "/v1/responses"
      }

      case Req.post(@api_url, json: req, headers: [{"content-type", "application/json"}]) do
        {:ok, %{status: status}} when status in 200..299 ->
          IO.puts("  ✓ /v1/responses request accepted")

        {:ok, %{status: status, body: body}} ->
          IO.puts("  ✗ /v1/responses failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          IO.puts("  ✗ /v1/responses error: #{inspect(reason)}")
      end
    end
  end

  # /v1/chat/completions - Chat Completions API
  defp send_chat_completions_requests do
    IO.puts("Sending 5 requests to /v1/chat/completions...")

    conversations = [
      [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "What is the capital of France?"}
      ],
      [
        %{"role" => "system", "content" => "You are a coding expert."},
        %{"role" => "user", "content" => "Write a hello world program in Python."}
      ],
      [
        %{"role" => "system", "content" => "You are a history teacher."},
        %{"role" => "user", "content" => "When did World War II end?"}
      ],
      [
        %{"role" => "system", "content" => "You are a math tutor."},
        %{"role" => "user", "content" => "What is the Pythagorean theorem?"}
      ],
      [
        %{"role" => "system", "content" => "You are a science expert."},
        %{"role" => "user", "content" => "What causes lightning?"}
      ]
    ]

    for messages <- conversations do
      req = %{
        "body" => %{
          "model" => "gpt-4o-mini",
          "messages" => messages
        },
        "custom_id" => Ecto.UUID.generate(),
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => @webhook_url
        },
        "method" => "POST",
        "url" => "/v1/chat/completions"
      }

      case Req.post(@api_url, json: req, headers: [{"content-type", "application/json"}]) do
        {:ok, %{status: status}} when status in 200..299 ->
          IO.puts("  ✓ /v1/chat/completions request accepted")

        {:ok, %{status: status, body: body}} ->
          IO.puts("  ✗ /v1/chat/completions failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          IO.puts("  ✗ /v1/chat/completions error: #{inspect(reason)}")
      end
    end
  end

  # /v1/embeddings - Embeddings API
  defp send_embeddings_requests do
    IO.puts("Sending 5 requests to /v1/embeddings...")

    texts = [
      "The quick brown fox jumps over the lazy dog.",
      "Machine learning is a subset of artificial intelligence.",
      "Climate change affects ecosystems worldwide.",
      "The stock market fluctuates based on various factors.",
      "Renewable energy sources include solar, wind, and hydro."
    ]

    for text <- texts do
      req = %{
        "body" => %{
          "model" => "text-embedding-3-small",
          "input" => text
        },
        "custom_id" => Ecto.UUID.generate(),
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => @webhook_url
        },
        "method" => "POST",
        "url" => "/v1/embeddings"
      }

      case Req.post(@api_url, json: req, headers: [{"content-type", "application/json"}]) do
        {:ok, %{status: status}} when status in 200..299 ->
          IO.puts("  ✓ /v1/embeddings request accepted")

        {:ok, %{status: status, body: body}} ->
          IO.puts("  ✗ /v1/embeddings failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          IO.puts("  ✗ /v1/embeddings error: #{inspect(reason)}")
      end
    end
  end
end

AllEndpointsScript.run()
