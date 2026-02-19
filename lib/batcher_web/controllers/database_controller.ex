defmodule BatcherWeb.DatabaseController do
  use BatcherWeb, :controller

  require Logger

  def download(conn, _params) do
    case snapshot_module().create_snapshot() do
      {:ok, %{path: path, filename: filename}} ->
        conn
        |> send_download({:file, path},
          filename: filename,
          content_type: "application/octet-stream"
        )

      {:error, reason} ->
        Logger.error("Failed to create DB snapshot: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to create database snapshot")
        |> redirect(to: "/settings")
    end
  end

  defp snapshot_module do
    Application.get_env(:batcher, :sqlite_snapshot_module, Batcher.Storage.SqliteSnapshot)
  end
end
