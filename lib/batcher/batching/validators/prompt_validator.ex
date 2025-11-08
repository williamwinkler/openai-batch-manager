defmodule Batcher.Batching.Validators.PromptValidator do
  @moduledoc """
  Validates prompt requests using OpenApiSpex schemas.

  This module can be used by:
  - HTTP controller (via OpenApiSpex.Plug.CastAndValidate)
  - RabbitMQ consumer (via validate/1 function)
  - Any other source that needs to validate prompt request bodies

  The OpenAPI schemas are the single source of truth for validation.
  """

  alias OpenApiSpex.Cast
  alias BatcherWeb.Schemas.{
    ResponsesRequestBodySchema,
    EmbeddingsRequestBodySchema,
    ModerationRequestBodySchema
  }

  @doc """
  Validates a prompt request body against the appropriate OpenAPI schema.

  The schema is determined by the `endpoint` discriminator field.

  Returns `{:ok, validated_body}` if validation succeeds, or
  `{:error, errors}` if validation fails.

  ## Examples

      iex> validate(%{
      ...>   "custom_id" => "req-001",
      ...>   "model" => "gpt-4o",
      ...>   "endpoint" => "/v1/responses",
      ...>   "input" => "Hello!",
      ...>   "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com"}
      ...> })
      {:ok, %{"custom_id" => "req-001", ...}}

      iex> validate(%{"endpoint" => "/v1/responses"})
      {:error, [%{message: "Missing required property: custom_id", ...}]}
  """
  def validate(body) when is_map(body) do
    # Get the endpoint discriminator to determine which schema to use
    endpoint = body["endpoint"] || body[:endpoint]

    case get_schema_for_endpoint(endpoint) do
      nil ->
        {:error,
         [
           %{
             message: "Invalid or missing endpoint. Must be one of: /v1/responses, /v1/embeddings, /v1/moderations",
             path: ["endpoint"]
           }
         ]}

      schema ->
        # Cast and validate against the schema
        case Cast.cast(schema, body) do
          {:ok, validated} ->
            {:ok, validated}

          {:error, errors} ->
            {:error, format_errors(errors)}
        end
    end
  end

  @doc """
  Same as validate/1 but raises on validation error.

  ## Examples

      iex> validate!(%{"endpoint" => "/v1/responses", ...})
      %{"custom_id" => "req-001", ...}

      iex> validate!(%{"endpoint" => "invalid"})
      ** (ArgumentError) Validation failed: Invalid or missing endpoint
  """
  def validate!(body) when is_map(body) do
    case validate(body) do
      {:ok, validated} ->
        validated

      {:error, errors} ->
        error_message =
          errors
          |> Enum.map(fn err -> "#{Enum.join(err.path, ".")}: #{err.message}" end)
          |> Enum.join("; ")

        raise ArgumentError, "Validation failed: #{error_message}"
    end
  end

  # Returns the OpenAPI schema for the given endpoint
  defp get_schema_for_endpoint("/v1/responses"), do: ResponsesRequestBodySchema.schema()
  defp get_schema_for_endpoint("/v1/embeddings"), do: EmbeddingsRequestBodySchema.schema()
  defp get_schema_for_endpoint("/v1/moderations"), do: ModerationRequestBodySchema.schema()
  defp get_schema_for_endpoint(_), do: nil

  # Formats OpenApiSpex cast errors into a simpler structure
  defp format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{reason: reason, path: path, value: value} ->
        %{
          message: reason || "Validation failed",
          path: path || [],
          value: value
        }

      error ->
        %{
          message: inspect(error),
          path: [],
          value: nil
        }
    end)
  end

  defp format_errors(error) do
    [%{message: inspect(error), path: [], value: nil}]
  end
end
