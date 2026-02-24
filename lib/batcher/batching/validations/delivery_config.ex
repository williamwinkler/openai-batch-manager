defmodule Batcher.Batching.Validations.DeliveryConfig do
  @moduledoc """
  Validates the delivery_config map structure.

  Supports two delivery types:
  - webhook: requires type="webhook" and a valid webhook_url
  - rabbitmq: requires rabbitmq_queue (queue-only delivery)
  """
  use Ash.Resource.Validation

  @impl true
  @doc false
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

  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_queue" => q} = config)
       when is_binary(q) and q != "" do
    cond do
      non_empty?(Map.get(config, "rabbitmq_exchange")) ->
        {:error, "rabbitmq_exchange is no longer supported; use rabbitmq_queue only"}

      non_empty?(Map.get(config, "rabbitmq_routing_key")) ->
        {:error, "rabbitmq_routing_key is no longer supported; use rabbitmq_queue only"}

      true ->
        :ok
    end
  end

  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_exchange" => e})
       when is_binary(e) and e != "" do
    {:error, "rabbitmq_exchange is no longer supported; use rabbitmq_queue only"}
  end

  defp validate_config(%{"type" => "rabbitmq", "rabbitmq_routing_key" => rk})
       when is_binary(rk) and rk != "" do
    {:error, "rabbitmq_routing_key is no longer supported; use rabbitmq_queue only"}
  end

  defp validate_config(%{"type" => "rabbitmq"}) do
    {:error, "rabbitmq_queue is required for rabbitmq delivery"}
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
