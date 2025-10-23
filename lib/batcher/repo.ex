defmodule Batcher.Repo do
  use AshSqlite.Repo,
    otp_app: :batcher
end
