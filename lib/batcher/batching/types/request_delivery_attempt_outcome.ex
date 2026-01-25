defmodule Batcher.Batching.Types.RequestDeliveryAttemptOutcome do
  @moduledoc """
  Request delivery outcome enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      success: [
        label: "Success",
        description: "The delivery attempt was successful"
      ],
      authorization_error: [
        label: "Authorization error",
        description: "The delivery attempt failed due to authorization failure"
      ],
      http_status_not_2xx: [
        label: "Status not 2xx",
        description: "The delivery attempt returned a non-2xx status code"
      ],
      timeout: [
        label: "Timeout",
        description: "The delivery attempt timed out"
      ],
      connection_error: [
        label: "Connection error",
        description: "The connection to the delivery endpoint failed"
      ],
      exchange_not_found: [
        label: "Exchange not found",
        description: "The RabbitMQ exchange was not found"
      ],
      queue_not_found: [
        label: "Queue not found",
        description: "The RabbitMQ queue was not found"
      ],
      rabbitmq_not_configured: [
        label: "RabbitMQ not configured",
        description: "RabbitMQ is not configured on the server"
      ],
      other: [
        label: "Other",
        description: "The delivery attempt failed for an unknown reason"
      ]
    ]
end
