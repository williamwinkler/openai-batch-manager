defmodule Batcher.Batching.Resources.Delivery do
  @moduledoc """
  Embedded resource representing delivery configuration for prompt results.

  Supports two delivery types:
  - webhook: Delivers results via HTTP POST to a specified URL
  - rabbitmq: Delivers results to a specified RabbitMQ queue
  """

  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :type, :atom do
      description "Delivery type: 'webhook' for HTTP POST delivery, 'rabbitmq' for message queue delivery"
      allow_nil? false
      constraints one_of: [:webhook, :rabbitmq]
      public? true
    end

    attribute :webhook_url, :string do
      description "HTTP/HTTPS URL to receive results (required when type is 'webhook')"
      allow_nil? true
      public? true
    end

    attribute :rabbitmq_queue, :string do
      description "RabbitMQ queue name to receive results (required when type is 'rabbitmq')"
      allow_nil? true
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      delivery_type = Ash.Changeset.get_attribute(changeset, :type)
      webhook_url = Ash.Changeset.get_attribute(changeset, :webhook_url)
      rabbitmq_queue = Ash.Changeset.get_attribute(changeset, :rabbitmq_queue)

      case delivery_type do
        :webhook ->
          cond do
            is_nil(webhook_url) or webhook_url == "" ->
              {:error,
               field: :webhook_url,
               message: "webhook_url is required when delivery type is webhook"}

            not is_nil(rabbitmq_queue) ->
              {:error,
               field: :rabbitmq_queue,
               message: "rabbitmq_queue must be nil when delivery type is webhook"}

            not String.match?(webhook_url, ~r/^https?:\/\/.+/) ->
              {:error,
               field: :webhook_url,
               message: "webhook_url must be a valid HTTP or HTTPS URL"}

            true ->
              :ok
          end

        :rabbitmq ->
          cond do
            is_nil(rabbitmq_queue) or rabbitmq_queue == "" ->
              {:error,
               field: :rabbitmq_queue,
               message: "rabbitmq_queue is required when delivery type is rabbitmq"}

            not is_nil(webhook_url) ->
              {:error,
               field: :webhook_url,
               message: "webhook_url must be nil when delivery type is rabbitmq"}

            true ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end
end
