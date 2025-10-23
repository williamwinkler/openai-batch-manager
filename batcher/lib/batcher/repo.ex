defmodule Batcher.Repo do
  use Ecto.Repo,
    otp_app: :batcher,
    adapter: Ecto.Adapters.SQLite3
end
