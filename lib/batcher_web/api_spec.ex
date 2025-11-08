defmodule BatcherWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the Batcher API using OpenApiSpex.

  Defines the API spec with proper anyOf discriminator for the three
  different request body types: /v1/responses, /v1/embeddings, /v1/moderations.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths}
  alias BatcherWeb.Router
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "OpenAPI Batch Manager API",
        version: "1.0.0",
        description: """
        API for managing batch processing of LLM prompts.

        The main endpoint `/v1/prompt` accepts three different request body types,
        discriminated by the `endpoint` field:
        - `/v1/responses` - Chat completions
        - `/v1/embeddings` - Text embeddings
        - `/v1/moderations` - Content moderation
        """
      },
      servers: [
        %{url: "http://localhost:4000", description: "Local development server"}
      ],
      paths: Paths.from_router(Router)
    }
    # Populate the #/components/schemas from the modules
    |> OpenApiSpex.resolve_schema_modules()
  end
end
