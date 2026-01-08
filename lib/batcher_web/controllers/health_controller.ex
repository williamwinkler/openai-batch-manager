defmodule BatcherWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestration (Docker, Kubernetes, etc.)

  Returns a simple 200 OK response with minimal overhead.
  Can be extended to include database connectivity checks if needed.
  """
  use BatcherWeb, :controller

  @doc """
  Simple health check that returns 200 OK.

  For a more comprehensive check, this could verify:
  - Database connectivity
  - Required services availability
  - Memory/disk thresholds

  For now, if the BEAM is running and responding, we're healthy.
  """
  def check(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end
end
