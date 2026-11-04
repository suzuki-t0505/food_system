defmodule FoodVault.ShipmentOrdersTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures
  import FoodVault.ShipmentOrdersFixtures

  alias FoodVault.{Inventories, Items, Repo, ShipmentOrders, Warehouses}
  alias FoodVault.Inventories.{InventoryLot, InventoryTransaction}
  alias FoodVault.ShipmentOrders.{ShipmentAllocation, ShipmentOrder, ShipmentOrderEvent}

  @date ~D[2026-11-15]

  setup do
    %{
      staff: user_fixture(%{role: :staff}),
      warehouse: warehouse_fixture(),
      item: item_fixture(%{units_per_case: 12})
    }
  end

  defp line(item, cases, pieces, extra \\ %{}) do
    Map.merge(%{item_id: item.id, req_cases: cases, req_pieces: pieces}, extra)
  end

  defp request(warehouse, lines, extra \\ %{}) do
    Map.merge(%{warehouse_id: warehouse.id, shipment_date: @date, lines: lines}, extra)
  end

  defp lot!(ctx, attrs) do
    lot_fixture(
      Map.merge(%{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id}, Map.new(attrs))
    )
  end

  defp reload(lot), do: Repo.get!(InventoryLot, lot.id)

  describe "allocate_shipment_order/2 先出し順と期限" do
    test "期限日 → 入荷日 → ロット ID の順に引き当てる", ctx do
      d2 =
        lot!(ctx, %{
          case_qty: 0,
          piece_qty: 5,
          expiration_date: ~D[2027-02-01],
          received_date: ~D[2026-11-02]
        })

      d1_late =
        lot!(ctx, %{
          case_qty: 0,
          piece_qty: 5,
          expiration_date: ~D[2027-01-01],
          received_date: ~D[2026-11-05]
        })

      d1_early =
        lot!(ctx, %{
          case_qty: 0,
          piece_qty: 5,
          expiration_date: ~D[2027-01-01],
          received_date: ~D[2026-11-01]
        })

      assert {:ok, %{shipment_order: order, replayed?: false}} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 0, 12)])
               )

      [shipment_line] = order.lines
      allocated = Map.new(shipment_line.allocations, &{&1.lot_id, &1.allocated_pieces})

      assert allocated == %{d1_early.id => 5, d1_late.id => 5, d2.id => 2}
      assert order.status == :allocated
      assert reload(d1_early).allocated_piece_qty == 5
      assert reload(d2).allocated_piece_qty == 2
    end

    test "出庫予定日より前に期限が切れるロットは引き当てない", ctx do
      expired = lot!(ctx, %{case_qty: 1, expiration_date: ~D[2026-11-14]})
      ok = lot!(ctx, %{case_qty: 1, expiration_date: @date})

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 1, 0)])
               )

      assert [%{lot_id: lot_id}] = hd(order.lines).allocations
      assert lot_id == ok.id
      assert reload(expired).allocated_case_qty == 0
    end

    test "最低許容期限日未満のロットは引き当てない", ctx do
      short = lot!(ctx, %{case_qty: 1, expiration_date: ~D[2026-12-01]})
      long = lot!(ctx, %{case_qty: 1, expiration_date: ~D[2027-03-01]})
      lines = [line(ctx.item, 1, 0, %{min_expiration_date: ~D[2027-01-01]})]

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(ctx.staff, request(ctx.warehouse, lines))

      assert [%{lot_id: lot_id}] = hd(order.lines).allocations
      assert lot_id == long.id
      assert reload(short).allocated_case_qty == 0
      assert hd(order.lines).min_expiration_date == ~D[2027-01-01]
    end

    test "他の倉庫のロットや、引当済みで有効在庫が無いロットは使わない", ctx do
      _other_warehouse = lot_fixture(%{item_id: ctx.item.id, case_qty: 5})
      lot!(ctx, %{case_qty: 1})

      assert {:ok, _} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 1, 0)])
               )

      assert {:error, :insufficient_stock, [%{shortage_cases: 1}]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 1, 0)])
               )
    end
  end

  describe "allocate_shipment_order/2 ケースと荷崩し" do
    test "ケース要求はケースのまま引き当てる(在庫は減らさない)", ctx do
      lot = lot!(ctx, %{case_qty: 3})

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 2, 0)])
               )

      assert [%{allocated_cases: 2, allocated_pieces: 0}] = hd(order.lines).allocations
      reloaded = reload(lot)
      assert {reloaded.case_qty, reloaded.allocated_case_qty} == {3, 2}
    end

    test "バラが足りなければ同一ロット内で荷崩しし、auto_break を 1 行記録する", ctx do
      lot = lot!(ctx, %{case_qty: 3, piece_qty: 2})

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 0, 5)])
               )

      reloaded = reload(lot)
      # 1 ケース(12 個)を開封: ケース 3→2、バラ 2→14、うち 5 個を引当
      assert {reloaded.case_qty, reloaded.piece_qty} == {2, 14}
      assert {reloaded.allocated_case_qty, reloaded.allocated_piece_qty} == {0, 5}

      assert [%{allocated_cases: 0, allocated_pieces: 5}] = hd(order.lines).allocations

      breaks = Repo.all(from t in InventoryTransaction, where: t.transaction_type == :auto_break)

      assert [
               %{
                 lot_id: lot_id,
                 case_diff: -1,
                 piece_diff: 12,
                 shipment_order_id: order_id,
                 user_id: user_id
               }
             ] = breaks

      assert {lot_id, order_id, user_id} == {lot.id, order.id, ctx.staff.id}
    end

    test "複数ケースの荷崩しも 1 ロット 1 行に合算する", ctx do
      lot!(ctx, %{case_qty: 5})

      assert {:ok, _} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 0, 30)])
               )

      assert [%{case_diff: -3, piece_diff: 36}] =
               Repo.all(from t in InventoryTransaction, where: t.transaction_type == :auto_break)
    end

    test "ケースとバラを同じロットから引き当てると引当明細は 1 行になる", ctx do
      lot!(ctx, %{case_qty: 3})

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 1, 3)])
               )

      assert [%{allocated_cases: 1, allocated_pieces: 3}] = hd(order.lines).allocations
      assert Repo.aggregate(ShipmentAllocation, :count) == 1
    end

    test "引当解除しても荷崩しは元に戻らない", ctx do
      lot = lot!(ctx, %{case_qty: 3})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 0, 5)])
        )

      assert {:ok, _} = ShipmentOrders.cancel_shipment_order(ctx.staff, order)

      reloaded = reload(lot)
      assert {reloaded.case_qty, reloaded.piece_qty} == {2, 12}
      assert {reloaded.allocated_case_qty, reloaded.allocated_piece_qty} == {0, 0}
    end
  end

  describe "allocate_shipment_order/2 在庫不足" do
    test "不足すると全体をロールバックし、オーダーも荷崩しも残らない", ctx do
      lot = lot!(ctx, %{case_qty: 1})

      assert {:error, :insufficient_stock, [shortage]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 0, 14)])
               )

      assert shortage == %{item_id: ctx.item.id, shortage_cases: 0, shortage_pieces: 2}

      assert Repo.aggregate(ShipmentOrder, :count) == 0
      assert Repo.aggregate(ShipmentAllocation, :count) == 0
      assert Repo.aggregate(ShipmentOrderEvent, :count) == 0
      reloaded = reload(lot)
      assert {reloaded.case_qty, reloaded.piece_qty} == {1, 0}

      assert Repo.aggregate(
               from(t in InventoryTransaction, where: t.transaction_type == :auto_break),
               :count
             ) == 0
    end

    test "不足した全明細分の不足数を返し、足りている明細の荷崩しも戻る", ctx do
      ok_item = item_fixture(%{units_per_case: 6})
      short_a = item_fixture()
      short_b = item_fixture()
      ok_lot = lot_fixture(%{warehouse_id: ctx.warehouse.id, item_id: ok_item.id, case_qty: 2})

      lot_fixture(%{
        warehouse_id: ctx.warehouse.id,
        item_id: short_a.id,
        case_qty: 0,
        piece_qty: 1
      })

      lines = [line(short_b, 2, 0), line(ok_item, 0, 3), line(short_a, 0, 4)]

      assert {:error, :insufficient_stock, shortages} =
               ShipmentOrders.allocate_shipment_order(ctx.staff, request(ctx.warehouse, lines))

      assert Enum.sort_by(shortages, & &1.item_id) ==
               Enum.sort_by(
                 [
                   %{item_id: short_b.id, shortage_cases: 2, shortage_pieces: 0},
                   %{item_id: short_a.id, shortage_cases: 0, shortage_pieces: 3}
                 ],
                 & &1.item_id
               )

      reloaded = reload(ok_lot)
      assert {reloaded.case_qty, reloaded.piece_qty, reloaded.allocated_piece_qty} == {2, 0, 0}
    end
  end

  describe "allocate_shipment_order/2 履歴と操作者" do
    test "created イベントに操作ユーザーが残る", ctx do
      lot!(ctx, %{case_qty: 1})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 1, 0)])
        )

      assert [%{event_type: :created, user_id: user_id, operator: nil}] = order.events
      assert user_id == ctx.staff.id
      assert is_nil(order.external_slip_id)
    end

    test "API の操作者は operator として残る", ctx do
      lot!(ctx, %{case_qty: 1})

      attrs = request(ctx.warehouse, [line(ctx.item, 1, 0)], %{external_slip_id: "SLIP-1"})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order({:api, "ship@example.com"}, attrs)

      assert [%{event_type: :created, user_id: nil, operator: "ship@example.com"}] = order.events
      assert order.external_slip_id == "SLIP-1"
    end

    test "viewer は拒否する", ctx do
      lot!(ctx, %{case_qty: 1})
      viewer = user_fixture(%{role: :viewer})

      assert {:error, :forbidden} =
               ShipmentOrders.allocate_shipment_order(
                 viewer,
                 request(ctx.warehouse, [line(ctx.item, 1, 0)])
               )

      assert Repo.aggregate(ShipmentOrder, :count) == 0
    end
  end

  describe "allocate_shipment_order/2 入力の検証" do
    test "明細が無い・数量が 0・商品の重複・不正な ID はエラーの一覧になる", ctx do
      lot!(ctx, %{case_qty: 5})

      assert {:error, :validation_failed, [%{path: ["lines"]}]} =
               ShipmentOrders.allocate_shipment_order(ctx.staff, request(ctx.warehouse, []))

      assert {:error, :validation_failed, [%{path: ["lines", 0, "req_cases"]}]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 0, 0)])
               )

      assert {:error, :validation_failed, [%{path: ["lines", 1, "item_id"], message: msg}]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 1, 0), line(ctx.item, 1, 0)])
               )

      assert msg =~ "重複"

      assert {:error, :validation_failed, errors} =
               ShipmentOrders.allocate_shipment_order(ctx.staff, %{
                 warehouse_id: "bad",
                 shipment_date: "x",
                 lines: [%{item_id: "bad", req_cases: "a"}]
               })

      paths = Enum.map(errors, & &1.path)
      assert ["warehouse_id"] in paths
      assert ["shipment_date"] in paths
      assert ["lines", 0, "item_id"] in paths
      assert ["lines", 0, "req_cases"] in paths
      assert Repo.aggregate(ShipmentOrder, :count) == 0
    end

    test "フォーム形式(文字列キー・インデックス付きの明細)を受け付ける", ctx do
      lot!(ctx, %{case_qty: 2})

      attrs = %{
        "warehouse_id" => ctx.warehouse.id,
        "shipment_date" => "2026-11-15",
        "external_slip_id" => "",
        "lines" => %{
          "0" => %{
            "item_id" => ctx.item.id,
            "req_cases" => "1",
            "req_pieces" => "",
            "min_expiration_date" => ""
          }
        }
      }

      assert {:ok, %{shipment_order: order}} =
               ShipmentOrders.allocate_shipment_order(ctx.staff, attrs)

      assert is_nil(order.external_slip_id)
    end

    test "アーカイブ済みの倉庫・商品は検証エラー", ctx do
      lot!(ctx, %{case_qty: 1})
      admin = user_scope_fixture()
      other_item = item_fixture()
      {:ok, _} = Items.archive_item(admin, other_item)

      assert {:error, :validation_failed, [%{path: ["lines", 0, "item_id"]}]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(other_item, 1, 0)])
               )

      archived = warehouse_fixture()
      {:ok, _} = Warehouses.archive_warehouse(admin, archived)

      assert {:error, :validation_failed, [%{path: ["warehouse_id"]}]} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(archived, [line(ctx.item, 1, 0)])
               )
    end
  end

  describe "allocate_shipment_order/2 external_slip_id の冪等" do
    setup ctx do
      lot!(ctx, %{case_qty: 5})
      %{attrs: request(ctx.warehouse, [line(ctx.item, 1, 0)], %{external_slip_id: "SLIP-9"})}
    end

    test "内容が一致する再送は既存を返し、履歴も引当も増えない", %{attrs: attrs, staff: staff} do
      {:ok, %{shipment_order: first, replayed?: false}} =
        ShipmentOrders.allocate_shipment_order({:api, "a"}, attrs)

      assert {:ok, %{shipment_order: second, replayed?: true}} =
               ShipmentOrders.allocate_shipment_order(staff, attrs)

      assert second.id == first.id
      assert Repo.aggregate(ShipmentOrder, :count) == 1
      assert Repo.aggregate(ShipmentOrderEvent, :count) == 1
      assert Repo.aggregate(ShipmentAllocation, :count) == 1
    end

    test "明細の並び順が違っても同じ内容として扱う", ctx do
      other = item_fixture()
      lot_fixture(%{warehouse_id: ctx.warehouse.id, item_id: other.id, case_qty: 2})
      lines = [line(ctx.item, 1, 0), line(other, 0, 2)]
      attrs = request(ctx.warehouse, lines, %{external_slip_id: "SLIP-ORDER"})

      {:ok, _} = ShipmentOrders.allocate_shipment_order({:api, "a"}, attrs)

      assert {:ok, %{replayed?: true}} =
               ShipmentOrders.allocate_shipment_order({:api, "a"}, %{
                 attrs
                 | lines: Enum.reverse(lines)
               })
    end

    test "内容が違えば idempotency_conflict", %{attrs: attrs, item: item} do
      {:ok, _} = ShipmentOrders.allocate_shipment_order({:api, "a"}, attrs)

      for changed <- [
            %{attrs | lines: [line(item, 2, 0)]},
            %{attrs | shipment_date: ~D[2026-11-16]},
            %{attrs | lines: [line(item, 1, 0, %{min_expiration_date: ~D[2027-01-01]})]},
            %{attrs | warehouse_id: warehouse_fixture().id}
          ] do
        assert {:error, :idempotency_conflict} =
                 ShipmentOrders.allocate_shipment_order({:api, "a"}, changed)
      end

      assert Repo.aggregate(ShipmentOrder, :count) == 1
    end

    test "取消済みの伝票 ID は、同じ ID で再度引当できる", %{attrs: attrs} do
      {:ok, %{shipment_order: first}} = ShipmentOrders.allocate_shipment_order({:api, "a"}, attrs)
      {:ok, _} = ShipmentOrders.cancel_shipment_order({:api, "a"}, first)

      assert {:ok, %{shipment_order: second, replayed?: false}} =
               ShipmentOrders.allocate_shipment_order({:api, "a"}, attrs)

      refute second.id == first.id
    end
  end

  describe "ship_shipment_order/2" do
    setup ctx do
      lot = lot!(ctx, %{case_qty: 3, piece_qty: 4})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 1, 3)])
        )

      %{lot: lot, order: order}
    end

    test "現在庫と引当済数を減らし、ship とオーダー履歴を残す", ctx do
      assert {:ok, %{shipment_order: shipped, replayed?: false}} =
               ShipmentOrders.ship_shipment_order(ctx.staff, ctx.order)

      assert shipped.status == :shipped
      assert shipped.shipped_at
      assert Enum.map(shipped.events, & &1.event_type) == [:created, :shipped]

      reloaded = reload(ctx.lot)
      assert {reloaded.case_qty, reloaded.piece_qty} == {2, 1}
      assert {reloaded.allocated_case_qty, reloaded.allocated_piece_qty} == {0, 0}

      assert [%{case_diff: -1, piece_diff: -3, shipment_order_id: order_id, user_id: user_id}] =
               Repo.all(from t in InventoryTransaction, where: t.transaction_type == :ship)

      assert {order_id, user_id} == {ctx.order.id, ctx.staff.id}
    end

    test "すでに出庫確定なら現状を返し、数量も履歴も増えない", ctx do
      {:ok, _} = ShipmentOrders.ship_shipment_order(ctx.staff, ctx.order)

      assert {:ok, %{shipment_order: order, replayed?: true}} =
               ShipmentOrders.ship_shipment_order(ctx.staff, ctx.order)

      assert order.status == :shipped
      assert length(order.events) == 2

      assert Repo.aggregate(
               from(t in InventoryTransaction, where: t.transaction_type == :ship),
               :count
             ) == 1

      assert reload(ctx.lot).case_qty == 2
    end

    test "取消済みのオーダーは確定できない", ctx do
      {:ok, _} = ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order)
      assert {:error, :invalid_state} = ShipmentOrders.ship_shipment_order(ctx.staff, ctx.order)
    end

    test "viewer は拒否する", ctx do
      viewer = user_fixture(%{role: :viewer})
      assert {:error, :forbidden} = ShipmentOrders.ship_shipment_order(viewer, ctx.order)
      assert reload(ctx.lot).case_qty == 3
    end
  end

  describe "cancel_shipment_order/3" do
    setup ctx do
      lot = lot!(ctx, %{case_qty: 3})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 2, 0)])
        )

      %{lot: lot, order: order}
    end

    test "引当済数だけを戻し、現在庫と引当明細は残る", ctx do
      assert {:ok, %{shipment_order: cancelled, replayed?: false}} =
               ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order, reason: "誤登録")

      assert cancelled.status == :cancelled
      assert [%{allocated_cases: 2}] = hd(cancelled.lines).allocations

      assert Enum.map(cancelled.events, &{&1.event_type, &1.reason}) == [
               created: nil,
               cancelled: "誤登録"
             ]

      reloaded = reload(ctx.lot)
      assert {reloaded.case_qty, reloaded.allocated_case_qty} == {3, 0}

      assert Repo.aggregate(
               from(t in InventoryTransaction, where: t.transaction_type != :receive),
               :count
             ) == 0
    end

    test "すでに取消済みなら現状を返し、何も増えない", ctx do
      {:ok, _} = ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order)

      assert {:ok, %{shipment_order: order, replayed?: true}} =
               ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order)

      assert length(order.events) == 2
      assert reload(ctx.lot).allocated_case_qty == 0
    end

    test "出庫確定済みは解除できない", ctx do
      {:ok, _} = ShipmentOrders.ship_shipment_order(ctx.staff, ctx.order)
      assert {:error, :invalid_state} = ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order)
    end

    test "解除後は同じ在庫を別のオーダーが引き当てられる", ctx do
      {:ok, _} = ShipmentOrders.cancel_shipment_order(ctx.staff, ctx.order)

      assert {:ok, _} =
               ShipmentOrders.allocate_shipment_order(
                 ctx.staff,
                 request(ctx.warehouse, [line(ctx.item, 3, 0)])
               )
    end
  end

  describe "発送システム起源のオーダー" do
    setup ctx do
      lot!(ctx, %{case_qty: 2})
      attrs = request(ctx.warehouse, [line(ctx.item, 1, 0)], %{external_slip_id: "EXT-1"})

      {:ok, %{shipment_order: order}} =
        ShipmentOrders.allocate_shipment_order({:api, "ship@example.com"}, attrs)

      %{order: order}
    end

    test "画面のユーザーは admin でも確定・解除できない", %{order: order} do
      for user <- [user_fixture(%{role: :staff}), admin_fixture()] do
        assert {:error, :forbidden} = ShipmentOrders.ship_shipment_order(user, order)
        assert {:error, :forbidden} = ShipmentOrders.cancel_shipment_order(user, order)
      end

      assert ShipmentOrders.get_shipment_order!(order.id).status == :allocated
    end

    test "API の操作者は確定・解除できる", %{order: order} do
      assert {:ok, %{shipment_order: shipped}} =
               ShipmentOrders.ship_shipment_order({:api, "ship@example.com"}, order)

      assert Enum.map(shipped.events, & &1.operator) == ["ship@example.com", "ship@example.com"]
    end
  end

  describe "一覧と参照" do
    test "状態・倉庫・出庫予定日・起源で絞り込める", ctx do
      screen = order_fixture()
      lot!(ctx, %{case_qty: 2})

      attrs =
        request(ctx.warehouse, [line(ctx.item, 1, 0)], %{
          external_slip_id: "EXT-2",
          shipment_date: ~D[2026-12-01]
        })

      {:ok, %{shipment_order: external}} =
        ShipmentOrders.allocate_shipment_order({:api, "x"}, attrs)

      {:ok, _} = ShipmentOrders.cancel_shipment_order({:api, "x"}, external)

      ids = fn params ->
        ShipmentOrders.list_shipment_orders(params).entries |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(%{"origin" => "screen"}) == [screen.id]
      assert ids.(%{"origin" => "external"}) == [external.id]
      assert ids.(%{"status" => "cancelled"}) == [external.id]
      assert ids.(%{"status" => "allocated"}) == [screen.id]
      assert ids.(%{"warehouse_id" => ctx.warehouse.id}) == [external.id]
      assert ids.(%{"shipment_date" => "2026-12-01"}) == [external.id]

      assert ids.(%{"status" => "bad", "shipment_date" => "bad", "warehouse_id" => "bad"}) ==
               Enum.sort([screen.id, external.id])
    end

    test "list_allocating_orders/1 は引当中のオーダーだけ返す", ctx do
      lot = lot!(ctx, %{case_qty: 5})

      {:ok, %{shipment_order: keep}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 1, 0)])
        )

      {:ok, %{shipment_order: cancel}} =
        ShipmentOrders.allocate_shipment_order(
          ctx.staff,
          request(ctx.warehouse, [line(ctx.item, 1, 0)])
        )

      {:ok, _} = ShipmentOrders.cancel_shipment_order(ctx.staff, cancel)

      assert [{%ShipmentOrder{id: id}, item_id, 1, 0}] =
               ShipmentOrders.list_allocating_orders(lot.id)

      assert {id, item_id} == {keep.id, ctx.item.id}
    end
  end

  describe "DB の制約" do
    test "引当済数が現在庫を超える更新は CHECK 制約が拒否する", ctx do
      lot = lot!(ctx, %{case_qty: 1})

      assert_raise Postgrex.Error, ~r/allocated_case_qty_in_range/, fn ->
        Inventories.update_lot_quantities(lot.id, allocated_case_qty: 2)
      end
    end

    test "オーダー履歴は更新・削除できない", _ctx do
      order_fixture()

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(ShipmentOrderEvent, set: [reason: "x"])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete_all(ShipmentOrderEvent) end
    end
  end
end
