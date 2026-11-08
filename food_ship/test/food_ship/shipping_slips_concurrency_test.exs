defmodule FoodShip.ShippingSlipsConcurrencyTest do
  # 実コミットで複数プロセスから同時に更新するため async: false
  use FoodShip.ConcurrencyCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.ShippingSlipsFixtures

  alias FoodShip.InventoryStub
  alias FoodShip.Repo
  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}

  setup {Req.Test, :set_req_test_from_context}

  # 画面の表示・伝票の作成では、在庫のデフォルト倉庫の取得が走る
  setup do
    InventoryStub.stub_defaults()
    :ok
  end

  @orders "/api/v1/shipment_orders"

  test "同じ伝票の再引当を同時に走らせても、データが壊れない(片方は :stale か :invalid_status)" do
    scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
    slip = slip_fixture(%{}, scope)

    # 一度通信失敗にして、2 回目以降は「過去に API を呼んでいる(照会する)」状態にする
    InventoryStub.routes([{"POST", @orders, &InventoryStub.timeout/1}])
    {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)

    order =
      InventoryStub.order(%{
        external_slip_id: slip.id,
        req_pieces: slip.total_piece_qty,
        allocations: [
          {"01JE0000000000000000000001", "2026-12-20", 20},
          {"01JE0000000000000000000002", "2026-12-25", 16}
        ]
      })

    InventoryStub.routes([
      {"GET", @orders, fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end},
      {"POST", @orders, fn conn -> InventoryStub.json(conn, 201, order) end}
    ])

    results = concurrently(4, fn _n -> ShippingSlips.allocate_shipping_slip(scope, pending) end)

    assert Enum.all?(results, fn
             {:ok, %ShippingSlip{status: :allocated}, _info} -> true
             {:error, :stale} -> true
             {:error, :invalid_status} -> true
             _other -> false
           end)

    assert Enum.any?(results, &match?({:ok, %ShippingSlip{status: :allocated}, _}, &1))

    row = Repo.get!(ShippingSlip, slip.id)
    assert row.status == :allocated
    assert row.inventory_order_id == order["order_id"]

    # 引当ロットは重複せず、2 行のまま
    assert Repo.aggregate(SlipAllocatedLot, :count) == 2
  end
end
