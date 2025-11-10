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
end
