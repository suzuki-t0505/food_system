defmodule FoodVaultWeb.Plugs.ApiFormatTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias FoodVaultWeb.Plugs.ApiFormat

  test "/api/ 配下は format を json にする" do
    conn = ApiFormat.call(conn(:post, "/api/v1/shipment_orders"), ApiFormat.init([]))

    assert Phoenix.Controller.get_format(conn) == "json"
  end

  test "それ以外のパスは変えない" do
    for path <- ["/", "/users/log_in", "/apiary", "/inventory_lots"] do
      conn = ApiFormat.call(conn(:get, path), ApiFormat.init([]))

      assert conn.private[:phoenix_format] == nil
    end
  end
end
