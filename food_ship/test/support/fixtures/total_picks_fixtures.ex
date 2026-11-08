defmodule FoodShip.TotalPicksFixtures do
  @moduledoc """
  `FoodShip.TotalPicks` のテスト用データ。公開 API 経由で作る。

  引当済みの伝票は、在庫 API のスタブ(`FoodShip.InventoryStub`)で `allocated` にする。
  使うテストは `async: false` にして `setup {Req.Test, :set_req_test_from_context}` を呼ぶこと
  (共有モード)。スタブは呼ぶたびに差し替わるので、テスト側のスタブは fixture のあとに登録する。
  """

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.ShippingSlipsFixtures

  alias FoodShip.{InventoryStub, ShippingSlips, TotalPicks}

  @orders "/api/v1/shipment_orders"

  @doc """
  引当済み(`allocated`)の伝票を作る。

  `attrs` は `slip_fixture/2` と同じ。`opts`:
    * `:scope` - 操作者(省略時は admin)
    * `:lots` - 引当ロット `[{"2026-12-20", pieces}]`(合計が出庫総数量と一致すること。
      省略時は期限 `2026-12-20` の 1 ロット)
  """
  def allocated_slip_fixture(attrs \\ %{}, opts \\ []) do
    scope = Keyword.get_lazy(opts, :scope, &user_scope_fixture/0)
    slip = slip_fixture(attrs, scope)
    lots = Keyword.get(opts, :lots, [{"2026-12-20", slip.total_piece_qty}])

    InventoryStub.routes([
      {"POST", @orders,
       fn conn ->
         order =
           InventoryStub.order(%{
             order_id: Ecto.ULID.generate(),
             external_slip_id: conn.assigns.body["external_slip_id"],
             req_pieces: slip.total_piece_qty,
             allocations:
               Enum.map(lots, fn {date, pieces} -> {Ecto.ULID.generate(), date, pieces} end)
           })

         InventoryStub.json(conn, 201, order)
       end}
    ])

    {:ok, slip, _info} = ShippingSlips.allocate_shipping_slip(scope, slip)
    slip.status == :allocated or raise "引当済みの伝票を作れませんでした: #{inspect(slip.status)}"
    slip
  end

  @doc """
  トータルピックを 1 件作る。同じ発注元・同じメーカーの引当済み伝票を `slips` 件(既定 2)束ねる。

  `opts`: `:date`(既定 `2026-11-20`)・`:slips`・`:scope`・`:client`・`:item`。
  `{pick, slips}` を返す。
  """
  def total_pick_fixture(opts \\ []) do
    scope = Keyword.get_lazy(opts, :scope, &user_scope_fixture/0)
    date = Keyword.get(opts, :date, ~D[2026-11-20])
    client = Keyword.get_lazy(opts, :client, &client_fixture/0)
    item = Keyword.get_lazy(opts, :item, &shipping_item_fixture/0)

    slips =
      for _ <- 1..Keyword.get(opts, :slips, 2) do
        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: date},
          scope: scope
        )
      end

    {:ok, [pick]} =
      TotalPicks.create_total_picks(scope, date, [{client.id, item.inventory_maker_id}])

    {TotalPicks.get_total_pick!(pick.id), slips}
  end
end
