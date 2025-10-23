defmodule Batcher.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BatcherWeb.Telemetry,
      Batcher.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:batcher, :ecto_repos), skip: skip_migrations?()},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:batcher, :ash_domains),
         Application.fetch_env!(:batcher, Oban)
       )},
      # Start a worker by calling: Batcher.Worker.start_link(arg)
      # {Batcher.Worker, arg},
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:batcher, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Batcher.PubSub},
      BatcherWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Batcher.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BatcherWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
