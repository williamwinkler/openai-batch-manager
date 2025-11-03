defmodule Batcher.Batching.Changes.ExtractRequestBody do
  @moduledoc """
  Extracts fields from the request_body argument and sets them as changeset attributes.

  Takes the embedded request body resource (which could be any of the three types)
  and extracts:
  - custom_id
  - model
  - endpoint
  - delivery_type (from nested delivery object)
  - webhook_url (from nested delivery object)
  - rabbitmq_queue (from nested delivery object)

  These extracted values are used to populate the Prompt resource attributes for storage.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    request_body = Ash.Changeset.get_argument(changeset, :request_body)

    case request_body do
      nil ->
        # This should be caught by validation, but handle gracefully
        changeset

      body ->
        # Extract common fields
        changeset =
          changeset
          |> Ash.Changeset.force_change_attribute(:custom_id, body.custom_id)
          |> Ash.Changeset.force_change_attribute(:model, body.model)
          |> Ash.Changeset.force_change_attribute(:endpoint, body.endpoint)

        # Extract delivery configuration from nested object
        case body.delivery do
          nil ->
            changeset

          delivery ->
            changeset
            |> Ash.Changeset.force_change_attribute(:delivery_type, delivery.type)
            |> maybe_set_webhook_url(delivery)
            |> maybe_set_rabbitmq_queue(delivery)
        end
    end
  end

  defp maybe_set_webhook_url(changeset, %{webhook_url: url}) when not is_nil(url) do
    Ash.Changeset.force_change_attribute(changeset, :webhook_url, url)
  end

  defp maybe_set_webhook_url(changeset, _), do: changeset

  defp maybe_set_rabbitmq_queue(changeset, %{rabbitmq_queue: queue}) when not is_nil(queue) do
    Ash.Changeset.force_change_attribute(changeset, :rabbitmq_queue, queue)
  end

  defp maybe_set_rabbitmq_queue(changeset, _), do: changeset
end
