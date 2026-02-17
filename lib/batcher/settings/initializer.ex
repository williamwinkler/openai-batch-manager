defmodule Batcher.Settings.Initializer do
  @moduledoc """
  Ensures the singleton settings row exists at startup.
  """
  require Logger

  @spec ensure_defaults() :: :ok
  def ensure_defaults do
    _ = Batcher.Settings.ensure_rate_limit_settings!()
    :ok
  rescue
    error ->
      Logger.warning("Failed to initialize settings defaults: #{inspect(error)}")
      :ok
  end
end
