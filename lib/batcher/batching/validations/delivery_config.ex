defmodule Batcher.Batching.Validations.DeliveryConfig do
  @moduledoc """
  Validates the delivery_config map structure.

  Supports two delivery types:
  - webhook: requires type="webhook" and a valid webhook_url
  - rabbitmq: two modes:
    - Default exchange mode: requires rabbitmq_queue (routes directly to queue)
    - Custom exchange mode: requires rabbitmq_exchange + rabbitmq_routing_key (rabbitmq_queue optional)
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    delivery_config = Ash.Changeset.get_attribute(changeset, :delivery_config)

    case validate_config(delivery_config) do
      :ok -> :ok
      {:error, message} -> {:error, field: :delivery_config, message: message}
    end
  end

  defp validate_config(%{"type" => "webhook", "webhook_url" => url}) when is_binary(url) do
    if valid_url?(url), do: :ok, else: {:error, "webhook_url must be a valid HTTP/HTTPS URL"}
  end

  defp validate_config(%{"type" => "webhook", "webhook_url" => _}) do
    {:error, "webhook_url must be a string"}
  end

  defp validate_config(%{"type" => "webhook"}) do
    {:error, "webhook_url is required for webhook delivery"}
  end

  # Mode 1: Default exchange - queue required, no exchange
  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_queue" => q} = config)
       when is_binary(q) and q != "" do
    # Ensure exchange is not set (or is empty) for default exchange mode
    exchange = Map.get(config, "rabbitmq_exchange")

    if is_nil(exchange) or exchange == "" do
      :ok
    else
      # Exchange is set, so we need routing_key
      validate_exchange_mode(config)
    end
  end

  # Mode 2: Custom exchange - exchange + routing_key required, queue optional
  defp validate_config(
         %{"type" => "rabbitmq", "rabbitmq_exchange" => e, "rabbitmq_routing_key" => rk} = config
       )
       when is_binary(e) and e != "" and is_binary(rk) and rk != "" do
    # Queue is optional here, but if provided must be valid
    case Map.get(config, "rabbitmq_queue") do
      nil -> :ok
      "" -> {:error, "rabbitmq_queue cannot be empty if provided"}
      q when is_binary(q) -> :ok
      _ -> {:error, "rabbitmq_queue must be a string"}
    end
  end

  # Error: exchange without routing_key
  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_exchange" => e})
       when is_binary(e) and e != "" do
    {:error, "rabbitmq_routing_key is required when rabbitmq_exchange is set"}
  end

  # Error: neither queue nor exchange
  defp validate_config(%{"type" => "rabbitmq"}) do
    {:error,
     "either rabbitmq_queue (for default exchange) or rabbitmq_exchange + rabbitmq_routing_key is required"}
  end

  defp validate_config(%{"type" => type}) do
    {:error, "unsupported delivery type: #{type}"}
  end

  defp validate_config(_) do
    {:error, "type is required"}
  end

  # Helper for when queue is provided but exchange is also set
  defp validate_exchange_mode(%{"rabbitmq_routing_key" => rk})
       when is_binary(rk) and rk != "" do
    :ok
  end

  defp validate_exchange_mode(_) do
    {:error, "rabbitmq_routing_key is required when rabbitmq_exchange is set"}
  end

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        host == "localhost" or String.contains?(host, ".")

      _ ->
        false
    end
  end
end
