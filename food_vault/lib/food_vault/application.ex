defmodule FoodVault.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FoodVaultWeb.Telemetry,
      FoodVault.Repo,
      {DNSCluster, query: Application.get_env(:food_vault, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FoodVault.PubSub},
      # Start a worker by calling: FoodVault.Worker.start_link(arg)
      # {FoodVault.Worker, arg},
      # Start to serve requests, typically the last entry
      FoodVaultWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FoodVault.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FoodVaultWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
