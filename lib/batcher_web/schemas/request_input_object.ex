defmodule BatcherWeb.Schemas.RequestInputObject do
  @behaviour OpenApiSpex.Schema

  @impl true
  def schema do
    Batcher.OpenAPI.Schemas.RequestInputObject.schema()
  end
end
