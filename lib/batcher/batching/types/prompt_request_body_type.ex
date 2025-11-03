defmodule Batcher.Batching.Types.PromptRequestBodyType do
  @moduledoc """
  Union type for prompt request bodies.

  Supports three different request body types based on the OpenAI endpoint:
  - responses_request: For /v1/responses endpoint
  - embeddings_request: For /v1/embeddings endpoint
  - moderation_request: For /v1/moderations endpoint

  This union type generates an OpenAPI `anyOf` schema, allowing the API
  to accept any of the three body types at the single /v1/prompt endpoint.
  """

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        responses_request: [
          type: Batcher.Batching.Resources.ResponsesRequestBody,
          tag: :endpoint,
          tag_value: "/v1/responses"
        ],
        embeddings_request: [
          type: Batcher.Batching.Resources.EmbeddingsRequestBody,
          tag: :endpoint,
          tag_value: "/v1/embeddings"
        ],
        moderation_request: [
          type: Batcher.Batching.Resources.ModerationRequestBody,
          tag: :endpoint,
          tag_value: "/v1/moderations"
        ]
      ]
    ]
end
