defmodule FoodVault.ShipmentOrdersConcurrencyTest do
  use FoodVault.ConcurrencyCase, async: false

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Repo, ShipmentOrders}
  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.ShipmentOrders.ShipmentOrder

  @date ~D[2026-11-15]

  defp request(warehouse, lines, extra \\ %{}) do
    Map.merge(%{warehouse_id: warehouse.id, shipment_date: @date, lines: lines}, extra)
  end

  test "同じ商品への同時引当でも、引当済数は現在庫を超えない" do
    warehouse = warehouse_fixture()
    item = item_fixture()
    lot = lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 0, piece_qty: 10})
    staff = user_fixture(%{role: :staff})
    attrs = request(warehouse, [%{item_id: item.id, req_cases: 0, req_pieces: 3}])

    results = concurrently(5, fn _ -> ShipmentOrders.allocate_shipment_order(staff, attrs) end)

    # 10 個を 3 個ずつ: 成功は 3 件、残りは在庫不足
    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &match?({:error, :insufficient_stock, _}, &1)) == 2

    reloaded = Repo.get!(InventoryLot, lot.id)
    assert reloaded.allocated_piece_qty == 9
    assert reloaded.allocated_piece_qty <= reloaded.piece_qty
    assert Repo.aggregate(ShipmentOrder, :count) == 3
  end

  test "同時の荷崩しでも、ケースとバラの合計が合う" do
    warehouse = warehouse_fixture()
    item = item_fixture(%{units_per_case: 10})
    lot = lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 2, piece_qty: 0})
    staff = user_fixture(%{role: :staff})
    attrs = request(warehouse, [%{item_id: item.id, req_cases: 0, req_pieces: 7}])

    results = concurrently(4, fn _ -> ShipmentOrders.allocate_shipment_order(staff, attrs) end)

    # 20 個を 7 個ずつ: 成功は 2 件(14 個)、3 件目は 6 個しか残らず不足
    assert Enum.count(results, &match?({:ok, _}, &1)) == 2

    reloaded = Repo.get!(InventoryLot, lot.id)
    assert reloaded.case_qty * 10 + reloaded.piece_qty == 20
    assert reloaded.allocated_piece_qty == 14
  end

  test "商品の並びが逆の複数明細を同時に引き当ててもデッドロックしない" do
    warehouse = warehouse_fixture()
    a = item_fixture()
    b = item_fixture()

    for item <- [a, b],
        do: lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 20})

    staff = user_fixture(%{role: :staff})

    lines = [%{item_id: a.id, req_cases: 1}, %{item_id: b.id, req_cases: 1}]

    results =
      concurrently(5, fn n ->
        ordered = if rem(n, 2) == 0, do: lines, else: Enum.reverse(lines)
        ShipmentOrders.allocate_shipment_order(staff, request(warehouse, ordered))
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.aggregate(ShipmentOrder, :count) == 5
  end

  test "同じ external_slip_id の同時登録は 1 件だけ作られ、他は既存を返す(500 にならない)" do
    warehouse = warehouse_fixture()
    item = item_fixture()
    lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 10})

    attrs =
      request(warehouse, [%{item_id: item.id, req_cases: 1}], %{external_slip_id: "SLIP-CONC"})

    results =
      concurrently(5, fn _ ->
        ShipmentOrders.allocate_shipment_order({:api, "ship@example.com"}, attrs)
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:ok, %{replayed?: false}}, &1)) == 1
    assert Repo.aggregate(ShipmentOrder, :count) == 1

    ids = for {:ok, %{shipment_order: order}} <- results, uniq: true, do: order.id
    assert length(ids) == 1
  end

  test "確定と解除が同時に走っても、片方だけが成功する" do
    warehouse = warehouse_fixture()
    item = item_fixture()
    lot = lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 3})
    staff = user_fixture(%{role: :staff})

    {:ok, %{shipment_order: order}} =
      ShipmentOrders.allocate_shipment_order(
        staff,
        request(warehouse, [%{item_id: item.id, req_cases: 2}])
      )

    results =
      concurrently(2, fn
        1 -> ShipmentOrders.ship_shipment_order(staff, order)
        2 -> ShipmentOrders.cancel_shipment_order(staff, order)
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_state}, &1)) == 1

    reloaded = Repo.get!(InventoryLot, lot.id)
    assert reloaded.allocated_case_qty == 0
    assert reloaded.case_qty in [1, 3]
  end

  test "引当と棚卸調整(減算)が同時に走っても、引当済数が現在庫を超えない" do
    warehouse = warehouse_fixture()
    item = item_fixture()
    lot = lot_fixture(%{warehouse_id: warehouse.id, item_id: item.id, case_qty: 0, piece_qty: 10})
    staff = user_fixture(%{role: :staff})
    admin = admin_fixture()

    results =
      concurrently(2, fn
        1 ->
          {:allocate,
           ShipmentOrders.allocate_shipment_order(
             staff,
             request(warehouse, [%{item_id: item.id, req_pieces: 7}])
           )}

        2 ->
          {:adjust,
           FoodVault.Inventories.adjust_inventory(admin, lot, %{piece_diff: -5, note: "棚卸"})}
      end)

    {:allocate, allocate} = List.keyfind(results, :allocate, 0)
    {:adjust, adjust} = List.keyfind(results, :adjust, 0)

    # 先に引当が通れば有効在庫は 3 で調整は拒否、先に調整が通れば残りは 5 で引当は不足
    assert [match?({:ok, _}, allocate), match?({:ok, _}, adjust)] |> Enum.count(& &1) == 1

    reloaded = Repo.get!(InventoryLot, lot.id)
    assert reloaded.allocated_piece_qty <= reloaded.piece_qty
  end
end
