defmodule Batcher.TokenEstimation.RequestEstimatorTest do
  use ExUnit.Case, async: true

  alias Batcher.TokenEstimation.RequestEstimator

  test "excludes top-level wrapper fields from /v1/responses request token estimate" do
    base_payload = %{
      "custom_id" => "short",
      "method" => "POST",
      "url" => "/v1/responses",
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "Hello world"
      }
    }

    wrapper_heavy_payload = %{
      "custom_id" => String.duplicate("x", 10_000),
      "method" => "POST",
      "url" => "/v1/responses",
      "delivery_config" => %{"type" => "webhook", "webhook_url" => "https://example.com"},
      "batch_id" => 999,
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "Hello world"
      }
    }

    {:ok, base} = RequestEstimator.estimate("/v1/responses", "unsupported-model", base_payload)

    {:ok, wrapper_heavy} =
      RequestEstimator.estimate("/v1/responses", "unsupported-model", wrapper_heavy_payload)

    assert base.request_tokens == wrapper_heavy.request_tokens
    assert base.capacity_tokens == wrapper_heavy.capacity_tokens
  end

  test "counts configured contextual fields for /v1/responses" do
    payload_without_context = %{
      "body" => %{"model" => "gpt-4o-mini", "input" => "Classify this ticket"}
    }

    payload_with_context = %{
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "Classify this ticket",
        "instructions" => "Return JSON output only",
        "prompt" => "Support triage prompt template",
        "tools" => [%{"type" => "function", "function" => %{"name" => "triage"}}],
        "text" => %{
          "format" => %{"type" => "json_schema", "name" => "triage_output"}
        },
        "temperature" => 0.1
      }
    }

    {:ok, without_context} =
      RequestEstimator.estimate("/v1/responses", "unsupported-model", payload_without_context)

    {:ok, with_context} =
      RequestEstimator.estimate("/v1/responses", "unsupported-model", payload_with_context)

    assert with_context.request_tokens > without_context.request_tokens
    assert with_context.capacity_tokens > without_context.capacity_tokens
  end

  test "counts endpoint-specific fields for /v1/chat/completions and ignores control knobs" do
    base_payload = %{
      "body" => %{
        "model" => "gpt-4o",
        "messages" => [%{"role" => "user", "content" => "Summarize this"}]
      }
    }

    control_only_delta_payload = %{
      "body" => %{
        "model" => "gpt-4o",
        "messages" => [%{"role" => "user", "content" => "Summarize this"}],
        "temperature" => 0.0,
        "top_p" => 1.0,
        "max_tokens" => 42,
        "metadata" => %{"trace" => "abc"}
      }
    }

    with_counted_context_payload = %{
      "body" => %{
        "model" => "gpt-4o",
        "messages" => [%{"role" => "user", "content" => "Summarize this"}],
        "tools" => [%{"type" => "function", "function" => %{"name" => "summarize"}}],
        "response_format" => %{"type" => "json_object"}
      }
    }

    {:ok, base} =
      RequestEstimator.estimate("/v1/chat/completions", "unsupported-model", base_payload)

    {:ok, control_only} =
      RequestEstimator.estimate(
        "/v1/chat/completions",
        "unsupported-model",
        control_only_delta_payload
      )

    {:ok, with_context} =
      RequestEstimator.estimate(
        "/v1/chat/completions",
        "unsupported-model",
        with_counted_context_payload
      )

    assert control_only.request_tokens == base.request_tokens
    assert with_context.request_tokens > base.request_tokens
  end

  test "uses fallback when tokenizer payload threshold is exceeded" do
    original = Application.get_env(:batcher, :token_estimation, [])

    on_exit(fn ->
      Application.put_env(:batcher, :token_estimation, original)
    end)

    Application.put_env(
      :batcher,
      :token_estimation,
      Keyword.merge(original, max_tokenizer_payload_bytes: 1)
    )

    payload = %{
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "small payload"
      }
    }

    {:ok, result} = RequestEstimator.estimate("/v1/responses", "gpt-4o-mini", payload)

    assert result.source == :fallback
  end

  test "applies separate request and capacity safety buffers" do
    original = Application.get_env(:batcher, :token_estimation, [])

    on_exit(fn ->
      Application.put_env(:batcher, :token_estimation, original)
    end)

    Application.put_env(
      :batcher,
      :token_estimation,
      Keyword.merge(original,
        request_safety_buffer: 1.0,
        safety_buffer: 1.5,
        max_tokenizer_payload_bytes: 1
      )
    )

    payload = %{
      "body" => %{
        "model" => "gpt-4o-mini",
        "input" => "buffer check"
      }
    }

    {:ok, result} = RequestEstimator.estimate("/v1/responses", "gpt-4o-mini", payload)

    assert result.capacity_tokens > result.request_tokens
  end
end
