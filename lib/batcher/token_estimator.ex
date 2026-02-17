defmodule Batcher.TokenEstimator do
  @moduledoc """
  Estimates input tokens for request payloads with a model-aware tokenizer.
  """

  require Logger

  @type estimate_result :: %{
          tokens: non_neg_integer(),
          source: :tiktoken | :fallback
        }

  @doc """
  Estimates input tokens for a request payload and model.

  Uses `tiktoken` for model-aware counting when feasible. Falls back to a
  conservative character-based estimate when the model is unsupported, tokenization
  fails, or payload size exceeds the configured tokenizer threshold.

  Always applies the configured safety buffer and returns `{:ok, result}`.

  ## Examples

      iex> {:ok, result} =
      ...>   Batcher.TokenEstimator.estimate_input_tokens(
      ...>     "doctest-unsupported-model",
      ...>     %{"body" => %{"input" => "hello world"}}
      ...>   )
      iex> result.source == :fallback
      true
      iex> result.tokens > 0
      true
  """
  @spec estimate_input_tokens(String.t(), map() | String.t()) :: {:ok, estimate_result()}
  def estimate_input_tokens(model, payload) when is_binary(model) do
    start_time = System.monotonic_time()
    text = normalize_payload(payload)
    payload_bytes = byte_size(text)
    safety_buffer = safety_buffer()

    result =
      if payload_bytes >= max_tokenizer_payload_bytes() do
        %{tokens: fallback_estimate(text, safety_buffer), source: :fallback}
      else
        case Tiktoken.count_tokens(model, text) do
          {:ok, tokens} when is_integer(tokens) and tokens >= 0 ->
            %{tokens: apply_buffer(tokens, safety_buffer), source: :tiktoken}

          {:error, reason} ->
            Logger.warning(
              "Token estimator falling back for unsupported model #{inspect(model)}: #{inspect(reason)}"
            )

            %{tokens: fallback_estimate(text, safety_buffer), source: :fallback}
        end
      end

    emit_timing_telemetry(start_time, model, payload_bytes, result)

    {:ok, result}
  rescue
    error ->
      rescue_start_time = System.monotonic_time()

      Logger.warning(
        "Token estimator failed for model #{inspect(model)}, using fallback: #{inspect(error)}"
      )

      text = normalize_payload(payload)
      payload_bytes = byte_size(text)

      result = %{
        tokens: fallback_estimate(text, safety_buffer()),
        source: :fallback
      }

      emit_timing_telemetry(rescue_start_time, model, payload_bytes, result)
      {:ok, result}
  end

  defp normalize_payload(payload) when is_binary(payload), do: payload

  defp normalize_payload(payload) when is_map(payload) do
    payload
    |> normalize_json_payload()
    |> JSON.encode!()
  end

  defp normalize_payload(payload), do: inspect(payload)

  defp normalize_json_payload(payload) when is_struct(payload) do
    payload
    |> Map.from_struct()
    |> normalize_json_payload()
  end

  defp normalize_json_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {key, normalize_json_payload(value)} end)
  end

  defp normalize_json_payload(payload) when is_list(payload) do
    Enum.map(payload, &normalize_json_payload/1)
  end

  defp normalize_json_payload(payload), do: payload

  defp fallback_estimate(text, safety_buffer) do
    chars_per_token = fallback_chars_per_token()
    raw = Float.ceil(byte_size(text) / chars_per_token) |> trunc()
    apply_buffer(raw, safety_buffer)
  end

  defp apply_buffer(tokens, safety_buffer) do
    Float.ceil(tokens * safety_buffer)
    |> trunc()
    |> max(1)
  end

  defp safety_buffer do
    Application.get_env(:batcher, :token_estimation, [])
    |> Keyword.get(:safety_buffer, 1.10)
  end

  defp fallback_chars_per_token do
    Application.get_env(:batcher, :token_estimation, [])
    |> Keyword.get(:fallback_chars_per_token, 3.5)
  end

  defp max_tokenizer_payload_bytes do
    Application.get_env(:batcher, :token_estimation, [])
    |> Keyword.get(:max_tokenizer_payload_bytes, 200_000)
  end

  defp emit_timing_telemetry(start_time, model, payload_bytes, %{tokens: tokens, source: source}) do
    duration_native = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration_native, :native, :microsecond) / 1000

    :telemetry.execute(
      [:batcher, :token_estimation, :stop],
      %{duration: duration_native, duration_ms: duration_ms},
      %{
        model: model,
        payload_bytes: payload_bytes,
        tokens: tokens,
        source: source
      }
    )

    Logger.info(
      "Token estimation model=#{model} source=#{source} payload_bytes=#{payload_bytes} tokens=#{tokens} duration_ms=#{Float.round(duration_ms, 2)}"
    )
  end
end
