defmodule FoodVault.Repo do
  use Ecto.Repo,
    otp_app: :food_vault,
    adapter: Ecto.Adapters.Postgres
end
