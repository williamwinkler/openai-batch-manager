defmodule Batcher.Batching.Changes.SetDeliveryConfig do
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), Keyword.t(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    delivery = Ash.Changeset.get_argument(changeset, :delivery)
    type = delivery.type

    case type do
      "webhook" ->
        url = Map.get(delivery, :webhook_url)

        case is_valid_url?(url) do
          true ->
            changeset
            |> Ash.Changeset.change_attribute(:delivery_type, :webhook)
            |> Ash.Changeset.change_attribute(:webhook_url, url)

          false ->
            Ash.Changeset.add_error(changeset, field: :webhook_url, message: "is required and must be a valid url")
        end

      "rabbitmq" ->
        queue = Map.get(delivery, :rabbitmq_queue)
        exchange = Map.get(delivery, :rabbitmq_exchange)

        if is_binary(queue) and queue != "" do
          changeset
          |> Ash.Changeset.change_attribute(:delivery_type, :rabbitmq)
          |> Ash.Changeset.change_attribute(:rabbitmq_queue, queue)
          |> maybe_set_exchange(exchange)
        else
          Ash.Changeset.add_error(changeset, field: :rabbitmq_queue, message: "is required")
        end

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :delivery_type,
          message: "Unsupported type. Expected 'webhook' or 'rabbitmq'"
        )
    end
  end

  defp is_valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and not is_nil(host) and host != "" ->
        # Ensure the host has at least one dot (e.g., example.com) or is localhost
        host == "localhost" or String.contains?(host, ".")

      _ ->
        false
    end
  end

  defp is_valid_url?(_), do: false

  defp maybe_set_exchange(changeset, exchange) when is_binary(exchange) do
    Ash.Changeset.change_attribute(changeset, :rabbitmq_exchange, exchange)
  end

  defp maybe_set_exchange(changeset, _), do: changeset
end
