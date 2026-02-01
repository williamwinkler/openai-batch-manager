defmodule Batcher.Batching.Validations.DeliveryConfig do
  @moduledoc """
  Validates the delivery_config map structure.

  Supports two delivery types:
  - webhook: requires type="webhook" and a valid webhook_url
  - rabbitmq: two mutually exclusive modes:
    - Default exchange mode: requires rabbitmq_queue only (no exchange/routing_key)
    - Custom exchange mode: requires rabbitmq_exchange + rabbitmq_routing_key (no queue)
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

  # Mode 1: Default exchange - queue required, no exchange/routing_key allowed
  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_queue" => q} = config)
       when is_binary(q) and q != "" do
    exchange = Map.get(config, "rabbitmq_exchange")
    routing_key = Map.get(config, "rabbitmq_routing_key")

    cond do
      non_empty?(exchange) and non_empty?(routing_key) ->
        {:error,
         "cannot specify both rabbitmq_queue and rabbitmq_exchange - use either queue (default exchange) or exchange + routing_key (custom exchange)"}

      non_empty?(exchange) ->
        {:error,
         "cannot specify both rabbitmq_queue and rabbitmq_exchange - use either queue (default exchange) or exchange + routing_key (custom exchange)"}

      non_empty?(routing_key) ->
        {:error,
         "cannot specify rabbitmq_routing_key with rabbitmq_queue - routing_key is only used with custom exchanges"}

      true ->
        :ok
    end
  end

  # Mode 2: Custom exchange - exchange + routing_key required, no queue allowed
  defp validate_config(
         %{"type" => "rabbitmq", "rabbitmq_exchange" => e, "rabbitmq_routing_key" => rk} = config
       )
       when is_binary(e) and e != "" and is_binary(rk) and rk != "" do
    queue = Map.get(config, "rabbitmq_queue")

    if non_empty?(queue) do
      {:error,
       "cannot specify both rabbitmq_queue and rabbitmq_exchange - use either queue (default exchange) or exchange + routing_key (custom exchange)"}
    else
      :ok
    end
  end

  # Error: exchange without routing_key
  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_exchange" => e})
       when is_binary(e) and e != "" do
    {:error, "rabbitmq_routing_key is required when rabbitmq_exchange is set"}
  end

  # Error: routing_key without exchange
  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_routing_key" => rk})
       when is_binary(rk) and rk != "" do
    {:error, "rabbitmq_exchange is required when rabbitmq_routing_key is set"}
  end

  # Error: neither queue nor exchange
  defp validate_config(%{"type" => "rabbitmq"}) do
    {:error,
     "either rabbitmq_queue (for default exchange) or rabbitmq_exchange + rabbitmq_routing_key (for custom exchange) is required"}
  end

  defp validate_config(%{"type" => type}) do
    {:error, "unsupported delivery type: #{type}"}
  end

  defp validate_config(_) do
    {:error, "type is required"}
  end

  defp non_empty?(nil), do: false
  defp non_empty?(""), do: false
  defp non_empty?(s) when is_binary(s), do: true
  defp non_empty?(_), do: false

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
