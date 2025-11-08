defmodule BatcherWeb.Schemas.MessageSchema do
  @moduledoc """
  OpenAPI schema for a chat message in the /v1/responses endpoint.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    type: :object,
    description: "A message in a conversation with role and content",
    required: [:role, :content],
    properties: %{
      role: %Schema{
        type: :string,
        enum: ["developer", "user", "assistant"],
        description: "The role of the message author"
      },
      content: %Schema{
        type: :string,
        description: "The text content of the message"
      }
    },
    example: %{
      "role" => "user",
      "content" => "Hello, how are you?"
    }
  })
end
