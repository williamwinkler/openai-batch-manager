defmodule BatcherWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the Batcher API using OpenApiSpex.

  Defines the API spec with proper anyOf discriminator for the three
  different request body types: /v1/responses, /v1/embeddings, /v1/moderations.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths}
  alias BatcherWeb.Router
  @behaviour OpenApi

  @version Mix.Project.config()[:version]

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "OpenAI Batch Manager API",
        version: @version,
        description: """
        API for managing batch processing of OpenAI requests.
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
