defmodule Batcher.RequestValidator do
  @moduledoc """
  Validates request data against the RequestInputObject schema.
  Uses the same OpenApiSpex schema as the HTTP CastAndValidate plug.
  """

  alias BatcherWeb.ApiSpec
  alias Batcher.Batching.Types.OpenaiBatchEndpoints

  @doc """
  Validates JSON string and casts to validated map with atom keys.
  Returns {:ok, validated_data} or {:error, reason}
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
  """
  def validate(data) when is_map(data) do
    spec = ApiSpec.spec()
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
