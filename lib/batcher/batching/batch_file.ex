defmodule Batcher.Batching.BatchFile do
  @moduledoc """
  Helper module for managing batch JSONL files on disk.

  Provides utilities for computing file paths, checking disk space,
  and managing batch file lifecycle.
  """

  # 10 MB
  @min_disk_space_bytes 10 * 1024 * 1024

  @doc """
  Computes the file path for a given batch ID.

  ## Examples

      iex> Batcher.Batching.BatchFile.file_path("abc123")
      "/var/lib/batcher/batches/batch_abc123.jsonl"
  """
  def file_path(batch_id) do
    base_path = base_path()
    Path.join(base_path, "batch_#{batch_id}.jsonl")
  end

  @doc """
  Returns the base directory where batch files are stored.

  Defaults to /var/lib/batcher/batches in production, or priv/batches in dev/test.
  Can be overridden with BATCH_STORAGE_PATH environment variable.
  """
  def base_path do
    Application.get_env(:batcher, :batch_storage)[:base_path]
  end

  @doc """
  Checks if there is at least 10MB of free disk space available.

  Returns {:ok, available_bytes} if sufficient space is available,
  or {:error, reason} if not enough space or check fails.

  Uses Erlang's :disksup module from :os_mon for cross-platform compatibility.
  """
  def check_disk_space do
    # Ensure os_mon application is started
    ensure_os_mon_started()

    base = base_path()

    # Get the actual path to check (directory or parent if it doesn't exist)
    path_to_check =
      case File.stat(base) do
        {:ok, _} -> base
        {:error, :enoent} -> Path.dirname(base)
        {:error, _} -> base
      end

    # Get disk info for all mounted filesystems
    case :disksup.get_disk_info() do
      disk_info when is_list(disk_info) ->
        find_disk_for_path(disk_info, path_to_check)

      _ ->
        {:error, "Failed to retrieve disk information"}
    end
  end

  @doc """
  Creates the batch storage directory if it doesn't exist.

  Returns :ok on success, {:error, reason} on failure.
  """
  def ensure_directory_exists do
    base = base_path()

    case File.mkdir_p(base) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create directory: #{inspect(reason)}"}
    end
  end

  @doc """
  Creates an empty JSONL file for the given batch ID.

  Returns {:ok, file_path} on success, {:error, reason} on failure.
  """
  def create_file(batch_id) do
    path = file_path(batch_id)

    case File.write(path, "") do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to create file: #{inspect(reason)}"}
    end
  end

  # Private helpers

  defp ensure_os_mon_started do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} -> :ok
      # Already started
      {:error, _} -> :ok
    end
  end

  defp find_disk_for_path(disk_info, path) do
    # Expand the path to get the absolute, canonical path
    expanded_path = Path.expand(path)

    # Find the disk that contains this path by finding the longest matching mount point
    disk_info
    |> Enum.map(fn {id, total_kib, available_kib, _capacity} ->
      # Convert mount point ID to string and calculate match score
      mount_point = to_string(id)

      match_score =
        if String.starts_with?(expanded_path, mount_point),
          do: String.length(mount_point),
          else: 0

      {mount_point, total_kib, available_kib, match_score}
    end)
    |> Enum.filter(fn {_mount, _total, _avail, score} -> score > 0 end)
    |> Enum.max_by(fn {_mount, _total, _avail, score} -> score end, fn -> nil end)
    |> case do
      nil ->
        # Fallback: use the first disk (usually root filesystem)
        case List.first(disk_info) do
          {_id, _total_kib, available_kib, _capacity} ->
            check_sufficient_space(available_kib)

          _ ->
            {:error, "No disk information available"}
        end

      {_mount, _total_kib, available_kib, _score} ->
        check_sufficient_space(available_kib)
    end
  end

  defp check_sufficient_space(available_kib) do
    available_bytes = available_kib * 1024

    if available_bytes >= @min_disk_space_bytes do
      {:ok, available_bytes}
    else
      {:error,
       "Insufficient disk space: #{format_bytes(available_bytes)} available, need at least #{format_bytes(@min_disk_space_bytes)}"}
    end
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
end
