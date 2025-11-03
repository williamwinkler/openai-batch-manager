defmodule Batcher.Batching.Resources.ModerationRequestBody do
  @moduledoc """
  Embedded resource representing the request body for /v1/moderations endpoint.

  Required fields:
  - custom_id: Unique identifier for this request
  - model: Model to use for moderation
  - endpoint: Must be "/v1/moderations"
  - input: Text or array of texts to moderate
  - delivery: Delivery configuration (webhook or rabbitmq)
  """

  use Ash.Resource,
    domain: Batcher.Batching,
    data_layer: :embedded

  attributes do
    attribute :custom_id, :string do
      description "Unique identifier for this request (used to match request with response)"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "OpenAI moderation model to use (e.g., 'omni-moderation-latest', 'text-moderation-latest')"
      allow_nil? false
      public? true
    end

    attribute :endpoint, :string do
      description "Must be '/v1/moderations' for this request type"
      allow_nil? false
      public? true
    end

    attribute :input, Batcher.Batching.Types.ModerationInput do
      description "Input text to moderate - can be a single string or an array of strings"
      allow_nil? false
      public? true
    end

    attribute :delivery, Batcher.Batching.Resources.Delivery do
      description "Delivery configuration specifying how to receive the moderation results"
      allow_nil? false
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

      if endpoint != "/v1/moderations" do
        {:error,
         field: :endpoint, message: "endpoint must be '/v1/moderations' for this request type"}
      else
        :ok
      end
    end
  end
end
