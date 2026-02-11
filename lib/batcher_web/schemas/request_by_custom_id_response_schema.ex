defmodule BatcherWeb.Schemas.RequestByCustomIdResponseSchema do
  @moduledoc """
  OpenAPI schema for request lookup by custom_id, including delivery history.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.{DeliveryConfigSchema, RequestDeliveryAttemptSchema}

  OpenApiSpex.schema(%Schema{
    title: "RequestByCustomIdResponse",
    type: :object,
    required: [
      :id,
      :batch_id,
      :custom_id,
      :url,
      :model,
      :state,
      :delivery_config,
      :created_at,
      :updated_at,
      :request_payload_size,
      :delivery_attempt_count,
      :delivery_attempts
    ],
    properties: %{
      id: %Schema{type: :integer, description: "Request ID", example: 42},
      batch_id: %Schema{type: :integer, description: "Parent batch ID", example: 7},
      custom_id: %Schema{
        type: :string,
        description: "Request custom identifier",
        example: "lookup_req_1"
      },
      url: %Schema{
        type: :string,
        description: "OpenAI endpoint used by this request",
        example: "/v1/responses"
      },
      model: %Schema{
        type: :string,
        description: "Model used by this request",
        example: "gpt-4o-mini"
      },
      state: %Schema{
        type: :string,
        description: "Current request state",
        example: "delivery_failed"
      },
      delivery_config: DeliveryConfigSchema,
      error_msg: %Schema{
        type: :string,
        nullable: true,
        description: "Processing error message if present",
        example: nil
      },
      created_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "UTC creation timestamp",
        example: "2026-02-11T12:00:00Z"
      },
      updated_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "UTC last update timestamp",
        example: "2026-02-11T12:10:00Z"
      },
      request_payload_size: %Schema{
        type: :integer,
        description: "Request payload size in bytes",
        example: 512
      },
      delivery_attempt_count: %Schema{
        type: :integer,
        description: "Number of delivery attempts recorded",
        example: 2
      },
      delivery_attempts: %Schema{
        type: :array,
        description: "Delivery attempt audit history",
        items: RequestDeliveryAttemptSchema
      }
    }
  })
end
