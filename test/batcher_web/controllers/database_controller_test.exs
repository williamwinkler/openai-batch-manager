defmodule BatcherWeb.DatabaseControllerTest do
  use BatcherWeb.ConnCase, async: false

  defmodule SnapshotFailMock do
    def create_snapshot, do: {:error, :boom}
  end

  defmodule SnapshotOkMock do
    def create_snapshot do
      path = Path.join(System.tmp_dir!(), "snapshot-ok-#{System.unique_integer([:positive])}.db")
      :ok = File.write(path, "snapshot-content")
      {:ok, %{path: path, filename: Path.basename(path)}}
    end
  end

  setup do
    original_snapshot_module = Application.get_env(:batcher, :sqlite_snapshot_module)

    on_exit(fn ->
      restore_env(:sqlite_snapshot_module, original_snapshot_module)
    end)

    :ok
  end

  describe "GET /settings/database/download" do
    test "returns snapshot file as attachment", %{conn: conn} do
      Application.put_env(:batcher, :sqlite_snapshot_module, SnapshotOkMock)
      conn = get(conn, "/settings/database/download")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "application/octet-stream"))

      disposition = get_resp_header(conn, "content-disposition") |> List.first()
      assert disposition =~ "attachment;"
      assert disposition =~ ".db"
      assert byte_size(conn.resp_body || "") > 0
    end

    test "redirects with flash when snapshot creation fails", %{conn: conn} do
      Application.put_env(:batcher, :sqlite_snapshot_module, SnapshotFailMock)

      conn = get(conn, "/settings/database/download")

      assert redirected_to(conn) == "/settings"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:batcher, key)
  defp restore_env(key, value), do: Application.put_env(:batcher, key, value)
end
