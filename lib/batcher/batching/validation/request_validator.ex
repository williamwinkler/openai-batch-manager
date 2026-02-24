defmodule Batcher.Batching.Validation.RequestValidator do
  @moduledoc """
  Validates request data against the RequestInputObject schema.
  Uses the same OpenApiSpex schema as the HTTP CastAndValidate plug.
  """

  alias Batcher.OpenAPI.Spec
  alias Batcher.Batching.Types.OpenaiBatchEndpoints

  @doc """
  Validates JSON string and casts to validated map with atom keys.
  Returns {:ok, validated_data} or {:error, reason}.

  ## Examples

      iex> {:ok, result} =
      ...>   Batcher.Batching.Validation.RequestValidator.validate_json(
      ...>     ~s({"custom_id":"abc-123","url":"/v1/responses","method":"POST","delivery_config":{"type":"webhook","webhook_url":"https://example.com/hook"},"body":{"model":"gpt-4o-mini","input":"hello"}})
      ...>   )
      iex> result.custom_id
      "abc-123"

      iex> {:error, {:invalid_json, _reason}} =
      ...>   Batcher.Batching.Validation.RequestValidator.validate_json("{not-json}")
  """
  def validate_json(json_string) when is_binary(json_string) do
    case JSON.decode(json_string) do
      {:ok, data} ->
        validate(data)

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  @doc """
  Validates map data using OpenApiSpex.cast_value/4.
  Same validation as HTTP plug but callable programmatically.

  ## Examples

      iex> {:ok, validated} =
      ...>   Batcher.Batching.Validation.RequestValidator.validate(%{
      ...>     "custom_id" => "id-1",
      ...>     "url" => "/v1/embeddings",
      ...>     "method" => "POST",
      ...>     "delivery_config" => %{"type" => "webhook", "webhook_url" => "https://example.com/hook"},
      ...>     "body" => %{"model" => "text-embedding-3-small", "input" => "hello"}
      ...>   })
      iex> validated.url
      "/v1/embeddings"

      iex> {:error, {:validation_failed, [_ | _]}} =
      ...>   Batcher.Batching.Validation.RequestValidator.validate(%{
      ...>     "custom_id" => "id-2",
      ...>     "url" => "/v1/not-a-real-endpoint",
      ...>     "method" => "POST",
      ...>     "delivery_config" => %{"type" => "webhook", "webhook_url" => "https://example.com/hook"},
      ...>     "body" => %{"model" => "gpt-4o-mini", "input" => "hello"}
      ...>   })
  """
  def validate(data) when is_map(data) do
    spec = Spec.spec()
    schema = spec.components.schemas["RequestInputObject"]

    # OpenApiSpex.cast_value validates and converts string keys to atoms
    case OpenApiSpex.cast_value(data, schema, spec, []) do
      {:ok, validated} ->
        # Additional enum validation (cast_value may not enforce enum constraints)
        validate_enums(validated)

      {:error, errors} ->
        {:error, {:validation_failed, format_errors(errors)}}
    end
  end

  defp validate_enums(%{url: url} = validated) do
    valid_urls = OpenaiBatchEndpoints.values()

    if url in valid_urls do
      {:ok, validated}
    else
      {:error, {:validation_failed, ["url: must be one of #{inspect(valid_urls)}"]}}
    end
  end

  defp validate_enums(validated), do: {:ok, validated}

  defp format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn error ->
      case error do
        %{path: path, reason: reason} when is_list(path) ->
          "#{Enum.join(path, ".")}: #{inspect(reason)}"

        %{path: path, reason: reason} ->
          "#{path}: #{inspect(reason)}"

        %{path: path} when is_list(path) ->
          "#{Enum.join(path, ".")}: validation failed"

        %{path: path} ->
          "#{path}: validation failed"

        other ->
          inspect(other)
      end
    end)
  end

  defp format_errors(error), do: inspect(error)
end
