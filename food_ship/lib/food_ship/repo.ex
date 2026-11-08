defmodule FoodShip.Repo do
  use Ecto.Repo,
    otp_app: :food_ship,
    adapter: Ecto.Adapters.Postgres

  use Scrivener, page_size: 20
end
