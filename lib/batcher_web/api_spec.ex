defmodule BatcherWeb.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  @impl true
  def spec do
    Batcher.OpenAPI.Spec.spec()
  end
end
