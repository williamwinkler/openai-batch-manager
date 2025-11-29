defmodule BatcherWeb.RequestController do
  use BatcherWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Batcher.Batching.Handlers
  alias BatcherWeb.Schemas.{RequestInputObject, ErrorResponseSchema, RequestResponseSchema}

  # OpenApiSpex plugs automatically validate and cast the request
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

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

    # Request body is already validated and cast by OpenApiSpex plug
    # Access the validated body from conn.body_params
    request_body = conn.body_params

    Logger.debug("Incomming request received with custom_id=#{request_body.custom_id}")

    case Handlers.RequestHandler.handle(request_body) do
      {:ok, request} ->
        Logger.info("Request add succesfully to batch #{request.batch_id}")

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
        |> json(Error)

      {:error, error} ->
        # Log the internal error details at error level
        Logger.error("Failed to create request",
          custom_id: request_body["custom_id"],
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
