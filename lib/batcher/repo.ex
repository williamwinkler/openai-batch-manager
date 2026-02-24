defmodule Batcher.Repo do
  @moduledoc """
  Ecto repository configuration and helper metadata.
  """
  use AshPostgres.Repo,
    otp_app: :batcher,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  # Used by AshPostgres data layer for migration generation.
  @impl true
  def installed_extensions do
    []
  end
end
