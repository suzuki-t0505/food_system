defmodule FoodVault.ShipmentOrdersFixtures do
  @moduledoc "`ShipmentOrders` のテスト用データ。引当の公開 API 経由で作る。"

  alias FoodVault.ShipmentOrders

  import FoodVault.AccountsFixtures, only: [user_fixture: 1]
  import FoodVault.InventoriesFixtures, only: [lot_fixture: 1]

  @doc """
  出庫オーダーを引当して返す。

  `warehouse_id`・`lines` を渡さなければ、ロット(3 ケース)を入荷してその商品を 1 ケース引き当てる。
  `actor`(既定は `staff` ユーザー)・`shipment_date`(既定 2026-11-15)・`external_slip_id` を指定できる。
  """
  def order_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {actor, attrs} = Map.pop_lazy(attrs, :actor, fn -> user_fixture(%{role: :staff}) end)
    attrs = Map.put_new(attrs, :shipment_date, ~D[2026-11-15])

    attrs =
      if Map.has_key?(attrs, :lines) do
        attrs
      else
        lot = lot_fixture(%{case_qty: 3})

        Map.merge(attrs, %{
          warehouse_id: lot.warehouse_id,
          lines: [%{item_id: lot.item_id, req_cases: 1, req_pieces: 0}]
        })
      end

    {:ok, %{shipment_order: order}} = ShipmentOrders.allocate_shipment_order(actor, attrs)
    order
  end
end
