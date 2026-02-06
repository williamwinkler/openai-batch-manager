defmodule BatcherWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the Batcher API using OpenApiSpex.

  Defines the API spec with proper anyOf discriminator for the three
  different request body types: /v1/responses, /v1/embeddings, /v1/moderations.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
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
        %Server{url: server_url()}
      ],
      paths: Paths.from_router(Router)
    }
    # Populate the #/components/schemas from the modules
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp server_url do
    endpoint_config = Application.get_env(:batcher, BatcherWeb.Endpoint)
    host = endpoint_config[:url][:host] || "localhost"
    port = endpoint_config[:http][:port] || 4000
    "http://#{host}:#{port}"
  end
end
