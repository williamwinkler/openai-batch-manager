defmodule Batcher.Batching.Validations.ValidateDeliveryConfig do
  @moduledoc """
  Validates that the appropriate delivery configuration is provided based on delivery_type.

  - If delivery_type is :webhook, webhook_url must be present and a valid URL
  - If delivery_type is :rabbitmq, rabbitmq_queue must be present and non-empty
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Try to get values from both arguments and attributes
    # (create_for_responses uses arguments, create_internal uses attributes)
    delivery_type = Ash.Changeset.get_attribute(changeset, :delivery_type)

    webhook_url =
      Ash.Changeset.get_argument(changeset, :webhook_url) ||
      Ash.Changeset.get_attribute(changeset, :webhook_url)

    rabbitmq_queue =
      Ash.Changeset.get_argument(changeset, :rabbitmq_queue) ||
      Ash.Changeset.get_attribute(changeset, :rabbitmq_queue)

    case delivery_type do
      :webhook ->
        cond do
          not is_nil(rabbitmq_queue) and rabbitmq_queue != "" ->
            {:error,
             field: :rabbitmq_queue,
             message: "rabbitmq_queue should not be provided when delivery_type is webhook"}

          is_nil(webhook_url) or webhook_url == "" ->
            {:error,
             field: :webhook_url, message: "webhook_url is required when delivery_type is webhook"}

          not valid_url?(webhook_url) ->
            {:error,
             field: :webhook_url, message: "webhook_url must be a valid HTTP or HTTPS URL"}

          true ->
            :ok
        end

      :rabbitmq ->
        cond do
          not is_nil(webhook_url) and webhook_url != "" ->
            {:error,
             field: :webhook_url,
             message: "webhook_url should not be provided when delivery_type is rabbitmq"}

          is_nil(rabbitmq_queue) or rabbitmq_queue == "" ->
            {:error,
             field: :rabbitmq_queue,
             message: "rabbitmq_queue is required when delivery_type is rabbitmq"}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and not is_nil(host) and host != "" ->
        # Ensure the host has at least one dot (e.g., example.com) or is localhost
        host == "localhost" or String.contains?(host, ".")

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false
end
