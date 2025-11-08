defmodule BatcherWeb.PromptController do
  use BatcherWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Batcher.Batching.Handlers.PromptRequestHandler
  alias BatcherWeb.Schemas.{PromptResponseSchema, ErrorResponseSchema}

  # OpenApiSpex plugs automatically validate and cast the request
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  alias BatcherWeb.Schemas.BatchPromptUnionRequestSchema

  operation(:create,
    summary: "Send a prompt for batch processing",
    request_body: {
      "Request body",
      "application/json",
      BatchPromptUnionRequestSchema,
      required: true
    },
    responses: [
      accepted: {"Prompt accepted for processing", "application/json", PromptResponseSchema},
      bad_request: {"Bad request - validation errors", "application/json", ErrorResponseSchema},
      conflict: {"Duplicate custom_id - a prompt with this custom_id already exists", "application/json", ErrorResponseSchema}
    ]
  )

  @doc """
  Creates a new prompt for batch processing.

  The request body has already been validated and cast by OpenApiSpex.CastAndValidate plug.
  If validation fails, the plug automatically returns a 400 error before this action is called.
  """
  def create(conn, _params) do
    require Logger

    # Request body is already validated and cast by OpenApiSpex plug
    # Access the validated body from conn.body_params
    request_body = conn.body_params

    Logger.debug("Prompt ingestion request received",
      custom_id: request_body["custom_id"],
      endpoint: request_body["endpoint"],
      model: request_body["model"]
    )

    case PromptRequestHandler.handle_ingest_request(request_body) do
      {:ok, prompt} ->
        Logger.info("Prompt created successfully",
          custom_id: prompt.custom_id,
          prompt_id: prompt.id
        )

        # Return JSON:API compatible response
        conn
        |> put_status(:accepted)
        |> json(%{custom_id: prompt.custom_id})

      {:error, :custom_id_already_taken} ->
        Logger.info("Duplicate custom_id rejected",
          custom_id: request_body["custom_id"]
        )

        conn
        |> put_status(:conflict)
        |> json(%{
          errors: [
            %{
              code: "custom_id_already_taken",
              title: "Duplicate Custom ID",
              detail: "A prompt with this custom_id already exists."
            }
          ]
        })

      {:error, error} ->
        # Log the internal error details at error level
        Logger.error("Failed to create prompt",
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

        # {:error, %Ash.Error.Invalid{} = error} ->
        #   # Handle Ash validation errors from BatchBuilder
        #   errors =
        #     error.errors
        #     |> Enum.map(fn err ->
        #       %{
        #         code: err.class || "invalid",
        #         title: err.message || "Validation failed",
        #         detail: Exception.message(err),
        #         source: %{pointer: "/#{err.field || "unknown"}"}
        #       }
        #     end)

        #   conn
        #   |> put_status(:unprocessable_entity)
        #   |> json(%{errors: errors})

        # {:error, other} ->
        #   # Generic error handler for unexpected errors
        #   conn
        #   |> put_status(:unprocessable_entity)
        #   |> json(%{
        #     errors: [
        #       %{
        #         code: "unknown_error",
        #         title: "Unknown Error",
        #         detail: inspect(other)
        #       }
        #     ]
        #   })
    end
  end
end
