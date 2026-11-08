defmodule FoodShip.ShippingSlipsFixtures do
  @moduledoc """
  `FoodShip.ShippingSlips` のテスト用データ。公開 API 経由で作る。

  伝票は `pending` で作る(引当は呼ばない。ただし、在庫のデフォルト倉庫の取得は走るので、
  使うテストは `setup` で `FoodShip.InventoryStub.stub_defaults/0` を呼んでおく)。既定は、標準 2 箱・バラ 12 個の商品を
  3 件(総バラ数 36・箱数 6)。
  """

  import FoodShip.AccountsFixtures, only: [user_scope_fixture: 0]
  import FoodShip.MastersFixtures

  alias FoodShip.ShippingSlips

  def slip_fixture(attrs \\ %{}, scope \\ nil) do
    attrs = Map.new(attrs)
    scope = scope || user_scope_fixture()

    attrs = Map.put_new_lazy(attrs, :client_id, fn -> client_fixture().id end)
    attrs = Map.put_new_lazy(attrs, :shipping_item_id, fn -> shipping_item_fixture().id end)
    attrs = Map.put_new(attrs, :scheduled_ship_date, ~D[2026-11-20])
    attrs = Map.put_new(attrs, :order_count, 3)

    {:ok, slip} = ShippingSlips.create_shipping_slip(scope, attrs)
    slip
  end
end
