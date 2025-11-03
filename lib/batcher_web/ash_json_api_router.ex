defmodule BatcherWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [Batcher.Batching],
    open_api: "/open_api",
    open_api_title: "OpenAI Batch Manager API"
end
