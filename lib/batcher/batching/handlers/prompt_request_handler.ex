defmodule Batcher.Batching.Handlers.PromptRequestHandler do
  @moduledoc """
  Orchestrates the prompt ingestion process.

  This module handles the business logic for ingesting a prompt request:
  1. Extracts fields from the validated request body
  2. Builds the appropriate payload based on endpoint type
  3. Assigns the prompt to a batch via BatchBuilder

  Note: Request validation is handled by OpenApiSpex.Plug.CastAndValidate
  before this module is called.
  """

  alias Batcher.Batching.Handlers.{RequestExtractor, PayloadBuilder}
  alias Batcher.BatchBuilder

  @doc """
  Handles a prompt ingest request.

  Takes a validated request body (already validated by OpenApiSpex)
  and creates a prompt via the BatchBuilder.

  Returns `{:ok, prompt}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> handle_ingest_request(%{
      ...>   "custom_id" => "req-001",
      ...>   "model" => "gpt-4o",
      ...>   "endpoint" => "/v1/responses",
      ...>   "input" => "Hello!",
      ...>   "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com"}
      ...> })
      {:ok, %Batcher.Batching.Prompt{...}}
  """
  def handle_ingest_request(request_body) when is_map(request_body) do
    require Logger

    Logger.debug("Extracting fields from request body")

    # Extract fields from validated request
    extracted = RequestExtractor.extract(request_body)

    Logger.debug("Fields extracted",
      custom_id: extracted.custom_id,
      endpoint: extracted.endpoint,
      model: extracted.model,
      delivery_type: extracted.delivery_type,
      webhook_url: extracted.webhook_url,
      rabbitmq_queue: extracted.rabbitmq_queue
    )

    # Get endpoint (already validated by OpenApiSpex)
    endpoint = extracted.endpoint

    # Build payload for the specific endpoint
    Logger.debug("Building payload for endpoint", endpoint: endpoint)
    payload = build_payload(endpoint, request_body)
    Logger.debug("Payload built", payload_keys: Map.keys(payload))

    # Assign to batch
    Logger.debug("Assigning prompt to batch")
    assign_to_batch(endpoint, extracted, payload)
  end

  # Builds the appropriate payload based on endpoint type
  # Request body is already validated, so these functions won't raise
  defp build_payload("/v1/responses", request_body) do
    PayloadBuilder.build_responses_payload(request_body)
  end

  defp build_payload("/v1/embeddings", request_body) do
    PayloadBuilder.build_embeddings_payload(request_body)
  end

  defp build_payload("/v1/moderations", request_body) do
    PayloadBuilder.build_moderation_payload(request_body)
  end

  # Assigns the prompt to a batch via BatchBuilder
  # Preserves the exact logic from AssignToBatch change
  defp assign_to_batch(endpoint, extracted, payload) do
    require Logger

    # Build prompt data for BatchBuilder
    prompt_data = %{
      custom_id: extracted.custom_id,
      endpoint: extracted.endpoint,
      model: extracted.model,
      request_payload: payload,
      delivery_type: extracted.delivery_type,
      webhook_url: extracted.webhook_url,
      rabbitmq_queue: extracted.rabbitmq_queue,
      tag: extracted.tag
    }

    Logger.debug(
      "Prompt data prepared for BatchBuilder: custom_id=#{prompt_data.custom_id} endpoint=#{prompt_data.endpoint} model=#{prompt_data.model} delivery_type=#{inspect(prompt_data.delivery_type)} webhook_url=#{inspect(prompt_data.webhook_url)} rabbitmq_queue=#{inspect(prompt_data.rabbitmq_queue)} tag=#{inspect(prompt_data.tag)}"
    )

    # Add to batch via BatchBuilder GenServer (preserves existing logic)
    Logger.debug("Calling BatchBuilder.add_prompt", endpoint: endpoint, model: extracted.model)

    case BatchBuilder.add_prompt(endpoint, extracted.model, prompt_data) do
      {:ok, prompt} ->
        Logger.debug("Prompt added to batch successfully",
          prompt_id: prompt.id,
          batch_id: prompt.batch_id
        )

        {:ok, prompt}

      {:error, :batch_full} ->
        Logger.debug("Batch full, retrying with new batch")
        # Retry once (will create new BatchBuilder for new batch)
        case BatchBuilder.add_prompt(endpoint, extracted.model, prompt_data) do
          {:ok, prompt} ->
            Logger.debug("Prompt added to new batch successfully",
              prompt_id: prompt.id,
              batch_id: prompt.batch_id
            )

            {:ok, prompt}

          error ->
            Logger.error("Failed to add prompt after batch full retry", error: inspect(error))
            {:error, {:batch_assignment_error, inspect(error)}}
        end

      {:error, :custom_id_already_taken} ->
        Logger.info("Duplicate custom_id rejected", custom_id: extracted.custom_id)
        {:error, :custom_id_already_taken}

      error ->
        Logger.error("Failed to add prompt to batch", error: inspect(error))
        {:error, {:batch_assignment_error, inspect(error)}}
    end
  end
end
