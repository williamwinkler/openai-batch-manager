defmodule Batcher.Batching.Resources.EmbeddingsRequestBody do
  @moduledoc """
  Embedded resource representing the request body for /v1/embeddings endpoint.

  Required fields:
  - custom_id: Unique identifier for this request
  - model: Model to use for embeddings
  - endpoint: Must be "/v1/embeddings"
  - input: Text or array of texts to embed
  - delivery: Delivery configuration (webhook or rabbitmq)

  Optional fields:
  - dimensions: Number of dimensions for the embedding vectors
  - encoding_format: Format of the embeddings (float or base64)
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
      description "OpenAI embedding model to use (e.g., 'text-embedding-3-large', 'text-embedding-3-small')"
      allow_nil? false
      public? true
    end

    attribute :endpoint, :string do
      description "Must be '/v1/embeddings' for this request type"
      allow_nil? false
      public? true
    end

    attribute :input, Batcher.Batching.Types.EmbeddingsInput do
      description "Input text to embed - can be a single string or an array of strings"
      allow_nil? false
      public? true
    end

    attribute :delivery, Batcher.Batching.Resources.Delivery do
      description "Delivery configuration specifying how to receive the embeddings"
      allow_nil? false
      public? true
    end

    # Optional parameters
    attribute :dimensions, :integer do
      description "Number of dimensions for the embedding vectors (only supported by text-embedding-3 models)"
      allow_nil? true
      constraints min: 1
      public? true
    end

    attribute :encoding_format, :atom do
      description "Format to return embeddings in: 'float' (default) or 'base64'"
      allow_nil? true
      constraints one_of: [:float, :base64]
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

      if endpoint != "/v1/embeddings" do
        {:error,
         field: :endpoint, message: "endpoint must be '/v1/embeddings' for this request type"}
      else
        :ok
      end
    end
  end
end
