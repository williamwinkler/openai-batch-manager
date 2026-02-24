defmodule Batcher.TokenEstimation.RequestEstimator do
  @moduledoc """
  Endpoint-aware token estimation for incoming request payloads.

  Produces both a request-focused estimate (for UI visibility) and a conservative
  capacity estimate (for admission control).
  """

  require Logger

  @type estimate_result :: %{
          request_tokens: non_neg_integer(),
          capacity_tokens: non_neg_integer(),
          source: :tiktoken | :fallback
        }

  @doc """
  Estimates request-level and capacity-level tokens for a payload.

  ## Examples

      iex> {:ok, result} =
      ...>   Batcher.TokenEstimation.RequestEstimator.estimate(
      ...>     "/v1/responses",
      ...>     "doctest-unsupported-model",
      ...>     %{"body" => %{"model" => "gpt-4o-mini", "input" => "hello world"}}
      ...>   )
      iex> result.source == :fallback
      true
      iex> result.request_tokens > 0 and result.capacity_tokens > 0
      true
  """
  @spec estimate(String.t(), String.t(), map() | String.t()) :: {:ok, estimate_result()}
  def estimate(url, model, payload) when is_binary(url) and is_binary(model) do
    payload_map = normalize_payload(payload)
    counted_input = build_counted_input(url, payload_map)
    text = JSON.encode!(counted_input)

    base_result = base_token_estimate(model, text)

    {:ok,
     %{
       request_tokens: apply_buffer(base_result.base_tokens, request_safety_buffer()),
       capacity_tokens: apply_buffer(base_result.base_tokens, capacity_safety_buffer()),
       source: base_result.source
     }}
  rescue
    error ->
      Logger.warning(
        "Request estimator failed for url=#{inspect(url)} model=#{inspect(model)}; using fallback: #{inspect(error)}"
      )

      text =
        payload |> normalize_payload() |> then(&build_counted_input(url, &1)) |> JSON.encode!()

      base_tokens = fallback_raw_estimate(text)

      {:ok,
       %{
         request_tokens: apply_buffer(base_tokens, request_safety_buffer()),
         capacity_tokens: apply_buffer(base_tokens, capacity_safety_buffer()),
         source: :fallback
       }}
  end

  defp base_token_estimate(model, text) do
    payload_bytes = byte_size(text)

    if payload_bytes >= max_tokenizer_payload_bytes() do
      %{base_tokens: fallback_raw_estimate(text), source: :fallback}
    else
      case Tiktoken.count_tokens(model, text) do
        {:ok, tokens} when is_integer(tokens) and tokens >= 0 ->
          %{base_tokens: tokens, source: :tiktoken}

        {:error, reason} ->
          Logger.warning(
            "Request estimator falling back for unsupported model #{inspect(model)}: #{inspect(reason)}"
          )

          %{base_tokens: fallback_raw_estimate(text), source: :fallback}
      end
    end
  end

  defp normalize_payload(payload) when is_binary(payload) do
    JSON.decode!(payload)
  end

  defp normalize_payload(payload) when is_map(payload), do: normalize_json_payload(payload)
  defp normalize_payload(payload), do: raise("unsupported payload: #{inspect(payload)}")

  defp normalize_json_payload(payload) when is_struct(payload) do
    payload
    |> Map.from_struct()
    |> normalize_json_payload()
  end

  defp normalize_json_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), normalize_json_payload(value)} end)
  end

  defp normalize_json_payload(payload) when is_list(payload) do
    Enum.map(payload, &normalize_json_payload/1)
  end

  defp normalize_json_payload(payload), do: payload

  defp build_counted_input(url, payload) when is_binary(url) and is_map(payload) do
    body = get_in(payload, ["body"]) || %{}

    %{
      "body" =>
        case url do
          "/v1/responses" ->
            body
            |> pick_fields(["input", "instructions", "prompt", "tools"])
            |> maybe_put("text", extract_text_format(body))

          "/v1/chat/completions" ->
            pick_fields(body, ["messages", "tools", "functions", "response_format"])

          "/v1/completions" ->
            pick_fields(body, ["prompt", "suffix"])

          "/v1/embeddings" ->
            pick_fields(body, ["input"])

          "/v1/moderations" ->
            pick_fields(body, ["input"])

          _ ->
            body
        end
    }
  end

  defp extract_text_format(body) when is_map(body) do
    case Map.get(body, "text") do
      text when is_map(text) -> pick_fields(text, ["format"])
      _ -> nil
    end
  end

  defp pick_fields(map, fields) when is_map(map) and is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case Map.fetch(map, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fallback_raw_estimate(text) do
    chars_per_token = fallback_chars_per_token()

    Float.ceil(byte_size(text) / chars_per_token)
    |> trunc()
    |> max(1)
  end

  defp apply_buffer(tokens, safety_buffer) do
    Float.ceil(tokens * safety_buffer)
    |> trunc()
    |> max(1)
  end

  defp request_safety_buffer do
    Application.get_env(:batcher, :token_estimation, [])
    |> Keyword.get(:request_safety_buffer, 1.0)
  end

  defp capacity_safety_buffer do
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
end
