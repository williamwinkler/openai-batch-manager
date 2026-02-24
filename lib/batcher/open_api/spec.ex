defmodule Batcher.OpenAPI.Spec do
  @moduledoc """
  Shared OpenAPI specification used by both web docs and backend validation.
  """

  alias BatcherWeb.Router
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

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
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp server_url do
    endpoint_config = Application.get_env(:batcher, BatcherWeb.Endpoint)
    host = endpoint_config[:url][:host] || "localhost"
    port = endpoint_config[:http][:port] || 4000
    "http://#{host}:#{port}"
  end
end
