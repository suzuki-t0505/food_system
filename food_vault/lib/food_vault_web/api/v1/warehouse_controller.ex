defmodule FoodVaultWeb.Api.V1.WarehouseController do
  @moduledoc "在庫 API ⑥: 有効な倉庫の一覧。"

  use FoodVaultWeb, :controller

  alias FoodVault.Warehouses

  def index(conn, _params) do
    render(conn, :index, warehouses: Warehouses.all_warehouses())
  end
end
