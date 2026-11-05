defmodule FoodVaultWeb.Api.V1.ItemController do
  @moduledoc """
  在庫 API ⑦: 有効な商品の検索。

  `?item_code=` で商品コードの完全一致、省略(または空)で有効な商品すべて。
  """

  use FoodVaultWeb, :controller

  alias FoodVault.Items

  def index(conn, params) do
    render(conn, :index, items: Items.search_active_items(params["item_code"]))
  end
end
