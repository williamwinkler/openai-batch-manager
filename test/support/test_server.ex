defmodule Batcher.TestServer do
  @doc """
  Utility for testing with a local HTTP server.
  """

  def expect_json_response(server, method, path, body_map, status) do
    TestServer.add(server, path,
      via: method,
      to: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, JSON.encode!(body_map))
      end
    )
  end
end
