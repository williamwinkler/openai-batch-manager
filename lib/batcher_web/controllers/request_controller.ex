defmodule BatcherWeb.RequestController do
  use BatcherWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Batcher.Batching
  alias Batcher.Batching.Handlers
  alias Batcher.System.MaintenanceGate

  alias BatcherWeb.Schemas.{
    ErrorResponseSchema,
    RequestByCustomIdResponseSchema,
    RequestInputObject,
    RequestRedeliverResponseSchema,
    RequestResponseSchema
  }

  # OpenApiSpex plugs automatically validate and cast the request
  plug :cast_and_validate when action in [:create]

  operation(:create,
    summary: "Send a request for batch processing",
    request_body: {
      "Request body",
      "application/json",
      RequestInputObject,
      required: true
    },
    responses: [
      accepted: {"Request accepted for processing", "application/json", RequestResponseSchema},
      bad_request: {"Bad request - validation errors", "application/json", ErrorResponseSchema},
      conflict:
        {"Duplicate custom_id - a request with this custom_id already exists", "application/json",
         ErrorResponseSchema}
    ]
  )

  @doc """
  Creates a new request for batch processing.

  The request body has already been validated and cast by OpenApiSpex.CastAndValidate plug.
  If validation fails, the plug automatically returns a 400 error before this action is called.
  """
  def create(conn, _params) do
    require Logger

    if MaintenanceGate.enabled?() do
      conn
      |> put_status(:service_unavailable)
      |> json(%{
        errors: [
          %{
            code: "maintenance_mode",
            title: "Service Temporarily Unavailable",
            detail: "Request intake is temporarily paused for maintenance. Please retry shortly."
          }
        ]
      })
    else
      # Request body is already validated and cast by OpenApiSpex plug
      # Access the validated body from conn.body_params
      request_body = conn.body_params

      Logger.debug("Incomming request received with custom_id=#{request_body.custom_id}")

      case Handlers.RequestHandler.handle(request_body) do
        {:ok, request} ->
          Logger.info(
            "Request #{request.custom_id} added succesfully to batch #{request.batch_id}"
          )

          conn
          |> put_status(:accepted)
          |> json(%RequestResponseSchema{
            custom_id: request.custom_id
          })

        {:error, :custom_id_already_taken} ->
          Logger.info("Duplicate custom_id rejected",
            custom_id: request_body.custom_id
          )

          conn
          |> put_status(:conflict)
          |> json(%{
            errors: [
              %{
                code: "duplicate_custom_id",
                title: "Custom ID Already Exists",
                detail: "A request with this custom_id already exists in the batch"
              }
            ]
          })

        {:error, error} ->
          # Log the internal error details at error level
          Logger.error("Failed to create request",
            custom_id: request_body.custom_id,
            error: inspect(error, pretty: true)
          )

          # Return generic error to client (don't leak internal details)
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            errors: [
              %{
                code: "internal_error",
                title: "Internal Server Error",
                detail: "An error occurred while processing your request. Please try again later."
              }
            ]
          })
      end
    end
  end

  operation(:show_by_custom_id,
    summary: "Get a request by custom_id",
    parameters: [
      custom_id: [in: :path, description: "Request custom_id", type: :string, required: true]
    ],
    responses: [
      ok: {"Request with delivery history", "application/json", RequestByCustomIdResponseSchema},
      not_found: {"Request not found", "application/json", ErrorResponseSchema},
      conflict: {"Multiple requests found for custom_id", "application/json", ErrorResponseSchema}
    ]
  )

  @doc """
  Fetches a request by custom_id and includes delivery attempt history.
  """
  def show_by_custom_id(conn, %{"custom_id" => custom_id}) do
    case Batching.list_requests_by_custom_id(custom_id, load: [:delivery_attempts]) do
      {:ok, []} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          errors: [
            %{
              code: "not_found",
              title: "Request Not Found",
              detail: "No request found with custom_id=#{custom_id}"
            }
          ]
        })

      {:ok, [request]} ->
        conn
        |> put_status(:ok)
        |> json(serialize_request(request))

      {:ok, requests} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          errors: [
            %{
              code: "ambiguous_custom_id",
              title: "Multiple Requests Found",
              detail:
                "Found #{length(requests)} requests with custom_id=#{custom_id}. custom_id should be globally unique."
            }
          ]
        })

      {:error, error} ->
        require Logger

        Logger.error("Failed to fetch request by custom_id",
          custom_id: custom_id,
          error: inspect(error, pretty: true)
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          errors: [
            %{
              code: "internal_error",
              title: "Internal Server Error",
              detail: "An error occurred while fetching the request."
            }
          ]
        })
    end
  end

  operation(:redeliver_by_custom_id,
    summary: "Trigger redelivery by custom_id",
    parameters: [
      custom_id: [in: :path, description: "Request custom_id", type: :string, required: true]
    ],
    responses: [
      accepted: {"Redelivery triggered", "application/json", RequestRedeliverResponseSchema},
      not_found: {"Request not found", "application/json", ErrorResponseSchema},
      conflict:
        {"Multiple requests found for custom_id", "application/json", ErrorResponseSchema},
      unprocessable_entity:
        {"Invalid state for redelivery", "application/json", ErrorResponseSchema}
    ]
  )

  @doc """
  Triggers redelivery for a request by custom_id if the request state allows it.
  """
  def redeliver_by_custom_id(conn, %{"custom_id" => custom_id}) do
    with {:ok, [request]} <- Batching.list_requests_by_custom_id(custom_id, load: [:batch]),
         {:ok, _batch} <- ensure_batch_ready_for_request_redelivery(request.batch),
         {:ok, updated_request} <- Batching.retry_request_delivery(request) do
      conn
      |> put_status(:accepted)
      |> json(%{
        id: updated_request.id,
        custom_id: updated_request.custom_id,
        state: updated_request.state,
        message: "Redelivery triggered"
      })
    else
      {:ok, []} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          errors: [
            %{
              code: "not_found",
              title: "Request Not Found",
              detail: "No request found with custom_id=#{custom_id}"
            }
          ]
        })

      {:ok, requests} when is_list(requests) ->
        conn
        |> put_status(:conflict)
        |> json(%{
          errors: [
            %{
              code: "ambiguous_custom_id",
              title: "Multiple Requests Found",
              detail:
                "Found #{length(requests)} requests with custom_id=#{custom_id}. custom_id should be globally unique."
            }
          ]
        })

      {:error, %Ash.Error.Invalid{} = error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: [
            %{
              code: "invalid_state",
              title: "Invalid Request State",
              detail: Exception.message(error)
            }
          ]
        })

      {:error, :invalid_batch_state} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: [
            %{
              code: "invalid_batch_state",
              title: "Invalid Batch State",
              detail:
                "Batch must be in delivering, partially_delivered, or delivery_failed state for request redelivery"
            }
          ]
        })

      {:error, error} ->
        require Logger

        Logger.error("Failed to redeliver request by custom_id",
          custom_id: custom_id,
          error: inspect(error, pretty: true)
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          errors: [
            %{
              code: "internal_error",
              title: "Internal Server Error",
              detail: "An error occurred while triggering redelivery."
            }
          ]
        })
    end
  end

  defp serialize_request(request) do
    attempts =
      request.delivery_attempts
      |> Enum.sort_by(& &1.attempted_at, {:desc, DateTime})
      |> Enum.map(fn attempt ->
        %{
          id: attempt.id,
          outcome: attempt.outcome,
          error_msg: attempt.error_msg,
          delivery_config: attempt.delivery_config,
          attempted_at: attempt.attempted_at
        }
      end)

    %{
      id: request.id,
      batch_id: request.batch_id,
      custom_id: request.custom_id,
      url: request.url,
      model: request.model,
      state: request.state,
      delivery_config: request.delivery_config,
      error_msg: request.error_msg,
      created_at: request.created_at,
      updated_at: request.updated_at,
      request_payload_size: request.request_payload_size,
      delivery_attempt_count: length(attempts),
      delivery_attempts: attempts
    }
  end

  defp ensure_batch_ready_for_request_redelivery(batch) do
    case batch.state do
      :delivering ->
        {:ok, batch}

      state when state in [:partially_delivered, :delivery_failed] ->
        Batching.begin_batch_redeliver(batch)

      _ ->
        {:error, :invalid_batch_state}
    end
  end

  defp cast_and_validate(conn, _opts) do
    OpenApiSpex.Plug.CastAndValidate.call(
      conn,
      OpenApiSpex.Plug.CastAndValidate.init(json_render_error_v2: true)
    )
  end
end
