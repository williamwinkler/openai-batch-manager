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

      iex> Batcher.Utils.Format.bytes(1024)
      "1.0 KB"

      iex> Batcher.Utils.Format.bytes(1_048_576)
      "1.0 MB"

      iex> Batcher.Utils.Format.bytes(1_073_741_824)
      "1.0 GB"

      iex> Batcher.Utils.Format.bytes(500)
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

      iex> Batcher.Utils.Format.time_ago(nil)
      "—"

      iex> Batcher.Utils.Format.time_ago(DateTime.add(DateTime.utc_now(), -30, :second))
      "<1m ago"

      iex> Batcher.Utils.Format.time_ago(DateTime.add(DateTime.utc_now(), 30, :second))
      "in the future"
  """
  def time_ago(datetime) when is_nil(datetime), do: "—"

  def time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 0 ->
        "in the future"

      diff < 60 ->
        "<1m ago"

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

  @doc """
  Formats elapsed time since a datetime as a compact duration.

  ## Examples

      iex> Batcher.Utils.Format.duration_since(nil)
      ""

      iex> Batcher.Utils.Format.duration_since(DateTime.add(DateTime.utc_now(), -30, :second))
      "less than 1m ago"
  """
  def duration_since(nil), do: ""

  def duration_since(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> duration_since()
  end

  def duration_since(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 ->
        "less than 1m ago"

      diff < 3600 ->
        "#{div(diff, 60)}m"

      diff < 86_400 ->
        "#{div(diff, 3600)}h #{rem(div(diff, 60), 60)}m"

      true ->
        "#{div(diff, 86_400)}d #{rem(div(diff, 3600), 24)}h"
    end
  end

  def duration_since(_), do: ""

  @doc """
  Formats a large integer into a compact human-readable number (K/M/B/T).

  ## Examples

      iex> Batcher.Utils.Format.compact_number(999)
      "999"

      iex> Batcher.Utils.Format.compact_number(1_000)
      "1K"

      iex> Batcher.Utils.Format.compact_number(125_000)
      "125K"

      iex> Batcher.Utils.Format.compact_number(1_250_000)
      "1.3M"
  """
  def compact_number(nil), do: "0"
  def compact_number(number) when number < 0, do: "-" <> compact_number(abs(number))

  def compact_number(number) when is_integer(number) do
    cond do
      number >= 1_000_000_000_000 -> format_compact(number, 1_000_000_000_000, "T")
      number >= 1_000_000_000 -> format_compact(number, 1_000_000_000, "B")
      number >= 1_000_000 -> format_compact(number, 1_000_000, "M")
      number >= 1_000 -> format_compact(number, 1_000, "K")
      true -> Integer.to_string(number)
    end
  end

  def compact_number(number) when is_float(number), do: compact_number(trunc(number))

  defp format_compact(number, divisor, suffix) do
    value = number / divisor

    display =
      if value >= 100 do
        Integer.to_string(trunc(value))
      else
        rounded = Float.round(value, 1)
        if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
      end

    display <> suffix
  end
end
