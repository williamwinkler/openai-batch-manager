defmodule Batcher.Storage.SqliteSnapshot do
  @moduledoc """
  Creates consistent SQLite database snapshots for download.
  """

  alias Ecto.Adapters.SQL

  @snapshot_prefix "openai-batch-manager-db-snapshot-"
  @snapshot_dir "batcher_snapshots"

  @type snapshot_info :: %{path: String.t(), filename: String.t()}

  @spec create_snapshot() :: {:ok, snapshot_info()} | {:error, term()}
  def create_snapshot do
    with {:ok, snapshot_path, filename} <- build_snapshot_path(),
         :ok <- vacuum_into(snapshot_path) do
      cleanup_old_snapshots()
      {:ok, %{path: snapshot_path, filename: filename}}
    end
  end

  defp build_snapshot_path do
    tmp_root = System.tmp_dir!()
    snapshot_root = Path.join(tmp_root, @snapshot_dir)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    filename = "#{@snapshot_prefix}#{timestamp}.db"
    path = Path.join(snapshot_root, filename)

    case File.mkdir_p(snapshot_root) do
      :ok -> {:ok, path, filename}
      {:error, reason} -> {:error, {:snapshot_dir_unavailable, reason}}
    end
  end

  defp vacuum_into(snapshot_path) do
    escaped_path = escape_sqlite_string(snapshot_path)
    sql = "VACUUM INTO '#{escaped_path}'"

    case SQL.query(Batcher.Repo, sql, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end

  defp escape_sqlite_string(path) when is_binary(path) do
    String.replace(path, "'", "''")
  end

  defp cleanup_old_snapshots do
    snapshot_root = Path.join(System.tmp_dir!(), @snapshot_dir)
    cutoff_unix = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix()

    with {:ok, entries} <- File.ls(snapshot_root) do
      Enum.each(entries, fn entry ->
        full_path = Path.join(snapshot_root, entry)

        if String.starts_with?(entry, @snapshot_prefix) do
          maybe_delete_old_snapshot(full_path, cutoff_unix)
        end
      end)
    end
  end

  defp maybe_delete_old_snapshot(path, cutoff_unix) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         mtime_dt <- NaiveDateTime.from_erl!(stat.mtime),
         mtime_unix <- DateTime.from_naive!(mtime_dt, "Etc/UTC") |> DateTime.to_unix(),
         true <- mtime_unix < cutoff_unix do
      _ = File.rm(path)
    else
      _ -> :ok
    end
  end
end
