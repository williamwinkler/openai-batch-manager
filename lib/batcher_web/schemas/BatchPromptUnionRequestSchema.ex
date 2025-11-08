defmodule BatcherWeb.Schemas.BatchPromptUnionRequestSchema do
  @moduledoc "Union of request bodies for responses, embeddings, and moderations."
  alias OpenApiSpex.{Schema, Discriminator}
  alias BatcherWeb.Schemas.{
    ResponsesRequestBodySchema,
    EmbeddingsRequestBodySchema,
    ModerationRequestBodySchema
  }

  @behaviour OpenApiSpex.Schema
  @impl true
  def schema do
    %Schema{
      title: "BatchPromptUnionRequest",
      description: "Request body must match exactly one of the supported endpoint shapes.",
      anyOf: [
        ResponsesRequestBodySchema,
        EmbeddingsRequestBodySchema,
        ModerationRequestBodySchema
      ],
      discriminator: %Discriminator{
        propertyName: "endpoint",
        mapping: %{
          "/v1/responses" => "#/components/schemas/ResponsesRequestBodySchema",
          "/v1/embeddings" => "#/components/schemas/EmbeddingsRequestBodySchema",
          "/v1/moderations" => "#/components/schemas/ModerationRequestBodySchema"
        }
      }
    }
  end
end
