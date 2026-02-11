defmodule BatcherWeb.Schemas.RequestDeliveryAttemptSchema do
  @moduledoc """
  OpenAPI schema for a single request delivery attempt.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.DeliveryConfigSchema

  OpenApiSpex.schema(%Schema{
    title: "RequestDeliveryAttempt",
    type: :object,
    required: [:id, :outcome, :delivery_config, :attempted_at],
    properties: %{
      id: %Schema{type: :integer, description: "Delivery attempt ID", example: 123},
      outcome: %Schema{
        type: :string,
        description: "Delivery attempt outcome",
        enum: [
          "success",
          "authorization_error",
          "timeout",
          "http_status_not_2xx",
          "connection_error",
          "queue_not_found",
          "exchange_not_found",
          "rabbitmq_not_configured",
          "other"
        ],
        example: "timeout"
      },
      error_msg: %Schema{
        type: :string,
        nullable: true,
        description: "Error message for failed attempts",
        example: "Request timed out"
      },
      delivery_config: DeliveryConfigSchema,
      attempted_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "UTC timestamp when the attempt occurred",
        example: "2026-02-11T12:34:56Z"
      }
    }
  })
end
