defmodule Batcher.Utils.Format do
  @moduledoc """
  Formatting utilities for human-readable output.

  Provides helpers for formatting bytes, timestamps, and other common
  display needs across the application.
  """

  @doc """
  Formats a byte count as a human-readable string.

  Automatically chooses the appropriate unit (GB, MB, KB, or bytes).

  ## Examples

      iex> Format.bytes(1024)
      "1.0 KB"

      iex> Format.bytes(1_048_576)
      "1.0 MB"

      iex> Format.bytes(1_073_741_824)
      "1.0 GB"

      iex> Format.bytes(500)
      "500 bytes"
  """
  def bytes(byte_count) when is_nil(byte_count), do: "0 bytes"

  def bytes(byte_count) do
    cond do
      byte_count >= 1024 * 1024 * 1024 ->
        "#{Float.round(byte_count / (1024 * 1024 * 1024), 2)} GB"

      byte_count >= 1024 * 1024 ->
        "#{Float.round(byte_count / (1024 * 1024), 2)} MB"

      byte_count >= 1024 ->
        "#{Float.round(byte_count / 1024, 2)} KB"

      true ->
        "#{byte_count} bytes"
    end
  end

  @doc """
  Formats a datetime as a relative time string (e.g., "10s ago", "1h ago", "2d ago").

  ## Examples

      iex> Format.time_ago(DateTime.add(DateTime.utc_now(), -30, :second))
      "30s ago"

      iex> Format.time_ago(DateTime.add(DateTime.utc_now(), -90, :minute))
      "1h ago"

      iex> Format.time_ago(DateTime.add(DateTime.utc_now(), -2, :day))
      "2d ago"
  """
  def time_ago(datetime) when is_nil(datetime), do: "—"

  def time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 0 ->
        "in the future"

      diff < 60 ->
        "#{diff}s ago"

      diff < 3600 ->
        minutes = div(diff, 60)
        "#{minutes}m ago"

      diff < 86400 ->
        hours = div(diff, 3600)
        "#{hours}h ago"

      diff < 604_800 ->
        days = div(diff, 86400)
        "#{days}d ago"

      diff < 2_592_000 ->
        weeks = div(diff, 604_800)
        "#{weeks}w ago"

      diff < 31_536_000 ->
        months = div(diff, 2_592_000)
        "#{months}mo ago"

      true ->
        years = div(diff, 31_536_000)
        "#{years}y ago"
    end
  end
end
