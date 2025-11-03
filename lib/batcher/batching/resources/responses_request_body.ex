defmodule Batcher.Batching.Resources.ResponsesRequestBody do
  @moduledoc """
  Embedded resource representing the request body for /v1/responses endpoint.

  Required fields:
  - custom_id: Unique identifier for this request
  - model: Model to use for the response
  - endpoint: Must be "/v1/responses"
  - input: Text or conversation messages
  - delivery: Delivery configuration (webhook or rabbitmq)

  Optional fields:
  - instructions: System message for the model
  - temperature: Sampling temperature (0-2)
  - max_output_tokens: Maximum tokens in response
  - top_p: Nucleus sampling parameter
  - store: Whether to store the response
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
      description "OpenAI model to use (e.g., 'gpt-4o', 'gpt-3.5-turbo')"
      allow_nil? false
      public? true
    end

    attribute :endpoint, :string do
      description "Must be '/v1/responses' for this request type"
      allow_nil? false
      public? true
    end

    attribute :input, Batcher.Batching.Types.ResponsesInput do
      description "Input text (string) or conversation messages (array of message objects with 'role' and 'content')"
      allow_nil? false
      public? true
    end

    attribute :delivery, Batcher.Batching.Resources.Delivery do
      description "Delivery configuration specifying how to receive the response"
      allow_nil? false
      public? true
    end

    # Optional parameters
    attribute :instructions, :string do
      description "System instructions for the model"
      allow_nil? true
      public? true
    end

    attribute :temperature, :float do
      description "Sampling temperature (0-2). Higher values make output more random"
      allow_nil? true
      constraints min: 0, max: 2
      public? true
    end

    attribute :max_output_tokens, :integer do
      description "Maximum number of tokens to generate in the response"
      allow_nil? true
      constraints min: 1
      public? true
    end

    attribute :top_p, :float do
      description "Nucleus sampling parameter (0-1). Alternative to temperature"
      allow_nil? true
      constraints min: 0, max: 1
      public? true
    end

    attribute :store, :boolean do
      description "Whether to store the response for later retrieval via API (default: true)"
      allow_nil? true
      default true
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

      if endpoint != "/v1/responses" do
        {:error,
         field: :endpoint, message: "endpoint must be '/v1/responses' for this request type"}
      else
        :ok
      end
    end
  end
end
