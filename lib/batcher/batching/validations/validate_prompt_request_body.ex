defmodule Batcher.Batching.Validations.ValidatePromptRequestBody do
  @moduledoc """
  Validates the request_body argument for the ingest action.

  Performs additional validation beyond what's done in the embedded resources:
  - Ensures the request body is valid
  - Validates that delivery configuration is properly structured
  - Additional cross-field validations if needed
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    request_body = Ash.Changeset.get_argument(changeset, :request_body)

    case request_body do
      nil ->
        {:error, field: :request_body, message: "request_body is required"}

      %{__struct__: struct_module} = body ->
        # Validate based on which request body type it is
        case struct_module do
          Batcher.Batching.Resources.ResponsesRequestBody ->
            validate_responses_request(body)

          Batcher.Batching.Resources.EmbeddingsRequestBody ->
            validate_embeddings_request(body)

          Batcher.Batching.Resources.ModerationRequestBody ->
            validate_moderation_request(body)

          _ ->
            {:error,
             field: :request_body,
             message: "request_body must be a valid request body type"}
        end

      _ ->
        {:error, field: :request_body, message: "request_body must be a valid embedded resource"}
    end
  end

  defp validate_responses_request(body) do
    # Additional validations specific to responses requests
    cond do
      is_nil(body.custom_id) or body.custom_id == "" ->
        {:error, field: :custom_id, message: "custom_id is required"}

      is_nil(body.model) or body.model == "" ->
        {:error, field: :model, message: "model is required"}

      is_nil(body.endpoint) ->
        {:error, field: :endpoint, message: "endpoint is required"}

      is_nil(body.input) ->
        {:error, field: :input, message: "input is required"}

      is_nil(body.delivery) ->
        {:error, field: :delivery, message: "delivery is required"}

      true ->
        :ok
    end
  end

  defp validate_embeddings_request(body) do
    # Additional validations specific to embeddings requests
    cond do
      is_nil(body.custom_id) or body.custom_id == "" ->
        {:error, field: :custom_id, message: "custom_id is required"}

      is_nil(body.model) or body.model == "" ->
        {:error, field: :model, message: "model is required"}

      is_nil(body.endpoint) ->
        {:error, field: :endpoint, message: "endpoint is required"}

      is_nil(body.input) ->
        {:error, field: :input, message: "input is required"}

      is_nil(body.delivery) ->
        {:error, field: :delivery, message: "delivery is required"}

      true ->
        :ok
    end
  end

  defp validate_moderation_request(body) do
    # Additional validations specific to moderation requests
    cond do
      is_nil(body.custom_id) or body.custom_id == "" ->
        {:error, field: :custom_id, message: "custom_id is required"}

      is_nil(body.model) or body.model == "" ->
        {:error, field: :model, message: "model is required"}

      is_nil(body.endpoint) ->
        {:error, field: :endpoint, message: "endpoint is required"}

      is_nil(body.input) ->
        {:error, field: :input, message: "input is required"}

      is_nil(body.delivery) ->
        {:error, field: :delivery, message: "delivery is required"}

      true ->
        :ok
    end
  end
end
