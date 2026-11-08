import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :food_ship, FoodShip.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("PGHOST", "db"),
  database: "food_ship_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :food_ship, FoodShipWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  secret_key_base: "XPN8+IcqG3PzL4waikMtwsqF4z7bkUF7E7nZX2N5a5HpXHsrm6qnz0iLQmCqajh1",
  server: false

# In test we don't send emails
config :food_ship, FoodShip.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# 在庫 API クライアント。HTTP は Req.Test のスタブに差し替える(待機なしでリトライ)
config :food_ship, FoodShip.Inventory.Client,
  base_url: "http://inventory.test",
  token: "test-inventory-api-token",
  warehouse_id: "01JA0000000000000000000000",
  connect_timeout: 1000,
  receive_timeout: 1000,
  retry_base_ms: 0,
  req_options: [plug: {Req.Test, FoodShip.Inventory.Client}]

# 未定義のログカテゴリは例外にする (本番は false)
config :food_ship, FoodShip.Utils.Logger, raise_on_unknown_category: true
