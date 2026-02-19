defmodule Batcher.Storage.DataReset do
  @moduledoc """
  Performs a clean-slate reset of local data while keeping the app runtime alive.
  """

  import Ecto.Query

  alias Batcher.Batching
  alias Batcher.OpenaiApiClient
  alias Batcher.Settings.Initializer
  alias Batcher.System.MaintenanceGate
  alias Ecto.Adapters.SQL
  alias Oban.Job

  require Logger

  @busy_retry_attempts 8
  @busy_retry_sleep_ms 150

  @app_tables [
    "request_delivery_attempts",
    "requests",
    "batch_transitions",
    "batches",
    "settings"
  ]

  @cancellable_job_states ["available", "scheduled", "retryable", "executing"]

  @spec erase_all() :: :ok | {:error, term()}
  def erase_all do
    :global.trans({__MODULE__, :erase_all}, fn ->
      do_erase_all()
    end)
  end

  defp do_erase_all do
    queues = configured_oban_queues()
    MaintenanceGate.enable!()

    try do
      pause_queues(queues)
      cancel_oban_jobs()
      cleanup_openai_files()
      clear_database_tables()
      vacuum_database()
      remove_local_batch_artifacts()
      Initializer.ensure_defaults()
      :ok
    rescue
      error ->
        Logger.error("Database reset failed: #{Exception.message(error)}")
        {:error, error}
    after
      resume_queues(queues)
      MaintenanceGate.disable!()
    end
  end

  defp configured_oban_queues do
    :batcher
    |> Application.fetch_env!(Oban)
    |> Keyword.get(:queues, [])
    |> Keyword.keys()
  end

  defp pause_queues(queues) do
    Enum.each(queues, fn queue ->
      case Oban.pause_queue(queue: queue) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to pause Oban queue #{queue}: #{inspect(reason)}")
      end
    end)
  end

  defp resume_queues(queues) do
    Enum.each(queues, fn queue ->
      case Oban.resume_queue(queue: queue) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to resume Oban queue #{queue}: #{inspect(reason)}")
      end
    end)
  end

  defp cancel_oban_jobs do
    query =
      Job
      |> where([job], job.state in ^@cancellable_job_states)

    {:ok, count} =
      with_sqlite_busy_retry(fn ->
        Oban.cancel_all_jobs(query)
      end)

    Logger.info("Cancelled #{count} Oban jobs before reset")
    :ok
  end

  defp cleanup_openai_files do
    case Batching.list_batches() do
      {:ok, batches} ->
        Enum.each(batches, fn batch ->
          [batch.openai_input_file_id, batch.openai_output_file_id, batch.openai_error_file_id]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.each(fn file_id ->
            case OpenaiApiClient.delete_file(file_id) do
              {:ok, _response} ->
                :ok

              {:error, error} ->
                Logger.warning(
                  "Failed to delete OpenAI file #{file_id} during reset: #{inspect(error)}"
                )
            end
          end)
        end)

      {:error, error} ->
        Logger.warning("Failed loading batches for OpenAI cleanup: #{inspect(error)}")
    end
  end

  defp clear_database_tables do
    oban_tables = fetch_oban_tables()
    tables = @app_tables ++ oban_tables

    Enum.each(tables, fn table ->
      with_sqlite_busy_retry(fn ->
        SQL.query!(Batcher.Repo, ~s(DELETE FROM "#{table}"), [])
      end)
    end)

    reset_sqlite_sequences(tables)
  end

  defp fetch_oban_tables do
    case SQL.query(
           Batcher.Repo,
           "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'oban_%'",
           []
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> name end)

      {:error, reason} ->
        Logger.warning("Failed fetching Oban tables for reset: #{inspect(reason)}")
        []
    end
  end

  defp reset_sqlite_sequences([]), do: :ok

  defp reset_sqlite_sequences(tables) do
    if sqlite_sequence_exists?() do
      table_names = Enum.map_join(tables, ",", &"'#{escape_sqlite_string(&1)}'")

      with_sqlite_busy_retry(fn ->
        SQL.query!(Batcher.Repo, "DELETE FROM sqlite_sequence WHERE name IN (#{table_names})", [])
      end)
    end
  end

  defp sqlite_sequence_exists? do
    case SQL.query(
           Batcher.Repo,
           "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'",
           []
         ) do
      {:ok, %{num_rows: count}} -> count > 0
      _ -> false
    end
  end

  defp vacuum_database do
    with_sqlite_busy_retry(fn ->
      SQL.query!(Batcher.Repo, "VACUUM", [])
    end)
  end

  defp remove_local_batch_artifacts do
    base_path =
      :batcher
      |> Application.get_env(:batch_storage, [])
      |> Keyword.get(:base_path)

    if is_binary(base_path) do
      case File.ls(base_path) do
        {:ok, entries} ->
          Enum.each(entries, fn entry ->
            _ = File.rm_rf(Path.join(base_path, entry))
          end)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed listing batch storage dir for cleanup: #{inspect(reason)}")
      end
    end
  end

  defp escape_sqlite_string(value) when is_binary(value) do
    String.replace(value, "'", "''")
  end

  defp with_sqlite_busy_retry(fun, attempt \\ 1)

  defp with_sqlite_busy_retry(fun, attempt) do
    fun.()
  rescue
    error ->
      if sqlite_busy_error?(error) and attempt < @busy_retry_attempts do
        Process.sleep(@busy_retry_sleep_ms * attempt)
        with_sqlite_busy_retry(fun, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp sqlite_busy_error?(%Exqlite.Error{message: message}) when is_binary(message) do
    String.contains?(String.downcase(message), "database busy")
  end

  defp sqlite_busy_error?(%DBConnection.ConnectionError{message: message})
       when is_binary(message) do
    String.contains?(String.downcase(message), "database busy")
  end

  defp sqlite_busy_error?(_), do: false
end
