defmodule BatcherWeb.Schemas.RequestRedeliverResponseSchema do
  @moduledoc """
  OpenAPI schema for redelivery trigger response.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    title: "RequestRedeliverResponse",
    type: :object,
    required: [:id, :custom_id, :state, :message],
    properties: %{
      id: %Schema{type: :integer, description: "Request ID", example: 42},
      custom_id: %Schema{
        type: :string,
        description: "Request custom identifier",
        example: "redeliver_req_1"
      },
      state: %Schema{
        type: :string,
        description: "New request state after triggering redelivery",
        example: "openai_processed"
      },
      message: %Schema{
        type: :string,
        description: "Redelivery status message",
        example: "Redelivery triggered"
      }
    }
  })
end
