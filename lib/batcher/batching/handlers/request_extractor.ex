defmodule Batcher.Batching.Handlers.RequestExtractor do
  @moduledoc """
  Extracts and normalizes fields from request bodies.

  Takes the validated request body (from HTTP JSON or Ash embedded resources)
  and extracts:
  - custom_id
  - model
  - endpoint
  - delivery_type (from nested delivery object)
  - webhook_url (from nested delivery object)
  - rabbitmq_queue (from nested delivery object)
  - tag (optional)

  These extracted values are used to populate the Prompt resource attributes for storage.
  """

  @doc """
  Extracts common fields from the request body.

  Returns a map with all extracted fields ready for database insertion.

  ## Examples

      iex> extract(%{
      ...>   "custom_id" => "req-001",
      ...>   "model" => "gpt-4o",
      ...>   "endpoint" => "/v1/responses",
      ...>   "delivery" => %{"type" => "webhook", "webhook_url" => "https://example.com"}
      ...> })
      %{
        custom_id: "req-001",
        model: "gpt-4o",
        endpoint: "/v1/responses",
        delivery_type: :webhook,
        webhook_url: "https://example.com",
        rabbitmq_queue: nil,
        tag: nil
      }
  """
  def extract(body) when is_map(body) do
    require Logger

    # Extract common fields (handle both atom and string keys)
    extracted = %{
      custom_id: get_field(body, "custom_id"),
      model: get_field(body, "model"),
      endpoint: get_field(body, "endpoint"),
      tag: get_field(body, "tag")
    }

    # Extract delivery configuration from nested object
    delivery = get_field(body, "delivery")

    Logger.debug("Extracting delivery configuration", delivery: inspect(delivery))

    result = extracted |> Map.merge(extract_delivery(delivery))

    Logger.debug("Extraction complete",
      custom_id: result.custom_id,
      delivery_type: result.delivery_type,
      webhook_url: result.webhook_url,
      rabbitmq_queue: result.rabbitmq_queue
    )

    result
  end

  @doc """
  Extracts delivery configuration from the nested delivery object.

  Returns a map with delivery_type, webhook_url, and rabbitmq_queue.
  """
  def extract_delivery(nil) do
    %{
      delivery_type: nil,
      webhook_url: nil,
      rabbitmq_queue: nil
    }
  end

  def extract_delivery(delivery) when is_map(delivery) do
    require Logger

    # Get delivery type (could be string or atom)
    delivery_type =
      case get_field(delivery, "type") do
        "webhook" -> :webhook
        "rabbitmq" -> :rabbitmq
        :webhook -> :webhook
        :rabbitmq -> :rabbitmq
        other -> other
      end

    webhook_url = get_field(delivery, "webhook_url")
    rabbitmq_queue = get_field(delivery, "rabbitmq_queue")

    Logger.debug(
      "Delivery fields extracted: delivery_type=#{inspect(delivery_type)} webhook_url=#{inspect(webhook_url)} rabbitmq_queue=#{inspect(rabbitmq_queue)}"
    )

    %{
      delivery_type: delivery_type,
      webhook_url: webhook_url,
      rabbitmq_queue: rabbitmq_queue
    }
  end

  # Helper to get a field from a map, trying both string and atom keys
  defp get_field(map, key) when is_map(map) and is_binary(key) do
    # Try string key first, then try atom key if the atom exists
    case Map.get(map, key) do
      nil ->
        # Try atom key only if it exists
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(map, atom_key)
        rescue
          ArgumentError -> nil
        end

      value ->
        value
    end
  end
end
