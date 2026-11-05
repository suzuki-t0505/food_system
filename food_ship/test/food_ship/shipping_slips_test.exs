defmodule FoodShip.ShippingSlipsTest do
  # Req.Test のスタブ・アプリ設定(倉庫 ID)を扱うため async: false
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.ShippingSlipsFixtures

  alias FoodShip.{Clients, ExpirationRules, ShippingItems, ShippingSlips}
  alias FoodShip.InventoryStub
  alias FoodShip.Inventory.Client, as: InventoryClient
  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}

  setup {Req.Test, :set_req_test_from_context}

  @orders "/api/v1/shipment_orders"
  @lot1 "01JE0000000000000000000001"
  @lot2 "01JE0000000000000000000002"
  @order_id "01JD0000000000000000000001"

  # 引当成功(合計 36 バラ = 3 件 × 12)の応答。ロットは 2 つ
  defp allocated_order(slip, attrs \\ %{}) do
    Map.merge(
      %{
        order_id: @order_id,
        external_slip_id: slip.id,
        req_pieces: slip.total_piece_qty,
        min_expiration_date:
          slip.min_expiration_date && Date.to_iso8601(slip.min_expiration_date),
        allocations: [{@lot1, "2026-12-20", 20}, {@lot2, "2026-12-25", slip.total_piece_qty - 20}]
      },
      attrs
    )
    |> InventoryStub.order()
  end

  defp route_allocate(fun), do: {"POST", @orders, fun}
  defp route_list(fun), do: {"GET", @orders, fun}
  defp route_cancel(fun), do: {"POST", ~r{/cancel$}, fun}

  defp respond_json(status, body), do: fn conn -> InventoryStub.json(conn, status, body) end

  defp slip_row(id), do: Repo.get!(ShippingSlip, id)
  defp lots_of(id), do: Repo.all(from l in SlipAllocatedLot, where: l.shipping_slip_id == ^id)

  defp viewer_scope,
    do: user_scope_fixture(user_fixture(%{role: :viewer, must_change_password: false}))

  defp staff_scope,
    do: user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))

  # 引当済みの伝票を作る(在庫 API はスタブ)
  defp allocated_slip(scope, attrs \\ %{}) do
    slip = slip_fixture(attrs, scope)

    InventoryStub.routes([route_allocate(respond_json(201, allocated_order(slip)))])
    {:ok, slip, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    InventoryStub.calls()
    slip
  end

  describe "create_shipping_slip/2" do
    test "マスタから計算して pending で保存し、在庫 API は呼ばない" do
      client = client_fixture()
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})

      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 30
      })

      scope = staff_scope()

      assert {:ok, slip} =
               ShippingSlips.create_shipping_slip(scope, %{
                 "client_id" => client.id,
                 "shipping_item_id" => item.id,
                 "scheduled_ship_date" => "2026-11-20",
                 "order_count" => "3",
                 "client_slip_no" => " PO-1 "
               })

      assert slip.status == :pending
      assert slip.order_count == 3
      assert slip.total_piece_qty == 36
      assert slip.box_count == 6
      assert slip.min_expiration_date == ~D[2026-12-20]
      assert slip.client_slip_no == "PO-1"
      assert slip.input_source == :manual
      assert slip.created_by_user_id == scope.user.id
      assert is_integer(slip.slip_no)
      assert ShippingSlip.slip_no_label(slip) =~ ~r/^S-\d{6}$/
      assert slip.inventory_order_id == nil
      assert slip.allocation_attempted_at == nil
      assert slip.client.id == client.id
      # 在庫 API を呼んでいない(スタブ未登録のため、呼べば失敗する)
      assert InventoryStub.calls() == []
    end

    test "出荷期限ルールが無ければ最低許容期限日は nil(制限なし)" do
      slip = slip_fixture()
      assert slip.min_expiration_date == nil
    end

    test "箱数は手修正でき、バラ数(出庫総数量)は手修正できない" do
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})

      slip = slip_fixture(%{shipping_item_id: item.id, box_count: 10, total_piece_qty: 999})

      assert slip.box_count == 10
      assert slip.total_piece_qty == 36
    end

    test "伝票番号は連番で採番される" do
      a = slip_fixture()
      b = slip_fixture()
      assert b.slip_no > a.slip_no
    end

    test "件数が 0・負数・数値でなければ changeset エラーで保存しない" do
      client = client_fixture()
      item = shipping_item_fixture()

      for count <- ["0", "-1", "abc", ""] do
        assert {:error, changeset} =
                 ShippingSlips.create_shipping_slip(staff_scope(), %{
                   client_id: client.id,
                   shipping_item_id: item.id,
                   scheduled_ship_date: "2026-11-20",
                   order_count: count
                 })

        assert Map.has_key?(errors_on(changeset), :order_count)
      end

      assert Repo.aggregate(ShippingSlip, :count) == 0
    end

    test "必須項目が無ければエラー" do
      assert {:error, changeset} = ShippingSlips.create_shipping_slip(staff_scope(), %{})

      assert %{client_id: _, shipping_item_id: _, scheduled_ship_date: _, order_count: _} =
               errors_on(changeset)
    end

    test "同じ発注元・発注元伝票番号・商品の二重登録は拒否する" do
      client = client_fixture()
      item = shipping_item_fixture()
      attrs = %{client_id: client.id, shipping_item_id: item.id, client_slip_no: "PO-9"}
      slip_fixture(attrs)

      assert {:error, changeset} =
               ShippingSlips.create_shipping_slip(staff_scope(), %{
                 client_id: client.id,
                 shipping_item_id: item.id,
                 client_slip_no: "PO-9",
                 scheduled_ship_date: "2026-11-21",
                 order_count: 1
               })

      assert %{client_slip_no: ["はすでに登録されています。"]} = errors_on(changeset)
      assert Repo.aggregate(ShippingSlip, :count) == 1
    end

    test "商品・発注元・番号のいずれかが違えば登録できる。番号なしは重複してよい" do
      client = client_fixture()
      item = shipping_item_fixture()
      slip_fixture(%{client_id: client.id, shipping_item_id: item.id, client_slip_no: "PO-9"})

      assert slip_fixture(%{client_id: client.id, client_slip_no: "PO-9"})
      assert slip_fixture(%{shipping_item_id: item.id, client_slip_no: "PO-9"})

      assert slip_fixture(%{
               client_id: client.id,
               shipping_item_id: item.id,
               client_slip_no: "PO-10"
             })

      assert slip_fixture(%{client_id: client.id, shipping_item_id: item.id})
      assert slip_fixture(%{client_id: client.id, shipping_item_id: item.id, client_slip_no: ""})
    end

    test "アーカイブ済みの発注元・発送商品は選べない" do
      admin = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture()
      {:ok, _} = Clients.archive_client(admin, client)
      {:ok, _} = ShippingItems.archive_shipping_item(admin, item)

      assert {:error, changeset} =
               ShippingSlips.create_shipping_slip(staff_scope(), %{
                 client_id: client.id,
                 shipping_item_id: item.id,
                 scheduled_ship_date: "2026-11-20",
                 order_count: 1
               })

      assert %{client_id: ["は選べません。"], shipping_item_id: ["は選べません。"]} =
               errors_on(changeset)
    end

    test "viewer は拒否する" do
      client = client_fixture()
      item = shipping_item_fixture()

      assert {:error, :forbidden} =
               ShippingSlips.create_shipping_slip(viewer_scope(), %{
                 client_id: client.id,
                 shipping_item_id: item.id,
                 scheduled_ship_date: "2026-11-20",
                 order_count: 1
               })

      assert Repo.aggregate(ShippingSlip, :count) == 0
    end

    test "対象倉庫が未設定なら保存しない" do
      client = client_fixture()
      item = shipping_item_fixture()

      without_warehouse(fn ->
        assert {:error, :warehouse_not_configured} =
                 ShippingSlips.create_shipping_slip(staff_scope(), %{
                   client_id: client.id,
                   shipping_item_id: item.id,
                   scheduled_ship_date: "2026-11-20",
                   order_count: 1
                 })
      end)

      assert Repo.aggregate(ShippingSlip, :count) == 0
    end
  end

  describe "preview/1" do
    test "件数・商品から出庫総数量と箱数の初期値を、ルールがあれば最低許容期限日を返す" do
      client = client_fixture()
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})

      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 45
      })

      assert %{
               total_piece_qty: 60,
               default_box_count: 10,
               min_remaining_days: 45,
               min_expiration_date: ~D[2027-01-04]
             } =
               ShippingSlips.preview(%{
                 "client_id" => client.id,
                 "shipping_item_id" => item.id,
                 "scheduled_ship_date" => "2026-11-20",
                 "order_count" => "5"
               })
    end

    test "ルールが無ければ最低許容期限日は nil" do
      client = client_fixture()
      item = shipping_item_fixture()

      assert %{total_piece_qty: 12, min_remaining_days: nil, min_expiration_date: nil} =
               ShippingSlips.preview(%{
                 "client_id" => client.id,
                 "shipping_item_id" => item.id,
                 "scheduled_ship_date" => "2026-11-20",
                 "order_count" => "1"
               })
    end

    test "入力が足りない・不正な項目は nil(例外にしない)" do
      assert %{total_piece_qty: nil, default_box_count: nil, min_expiration_date: nil} =
               ShippingSlips.preview(%{})

      assert %{total_piece_qty: nil} =
               ShippingSlips.preview(%{
                 "client_id" => "x",
                 "shipping_item_id" => "not-a-ulid",
                 "scheduled_ship_date" => "bad",
                 "order_count" => "-3"
               })

      item = shipping_item_fixture()

      assert %{total_piece_qty: nil} =
               ShippingSlips.preview(%{"shipping_item_id" => item.id, "order_count" => "0"})
    end
  end

  describe "allocate_shipping_slip/2: 成功" do
    test "引当済みになり、オーダー ID と引当ロットを保存する。要求に operator などが付く" do
      client = client_fixture()
      item = shipping_item_fixture()

      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 30
      })

      scope = staff_scope()
      slip = slip_fixture(%{client_id: client.id, shipping_item_id: item.id}, scope)

      InventoryStub.routes([route_allocate(respond_json(201, allocated_order(slip)))])

      assert {:ok, allocated, %{}} = ShippingSlips.allocate_shipping_slip(scope, slip)

      assert allocated.status == :allocated
      assert allocated.inventory_order_id == @order_id
      assert allocated.shortage_pieces == nil
      assert allocated.allocation_error == nil
      assert %DateTime{} = allocated.allocation_attempted_at

      assert [
               %{inventory_lot_id: @lot1, expiration_date: ~D[2026-12-20], allocated_pieces: 20},
               %{inventory_lot_id: @lot2, expiration_date: ~D[2026-12-25], allocated_pieces: 16}
             ] = allocated.allocated_lots

      # 初回は在庫側に旧オーダーが無いので、照会しない
      assert [{"POST", @orders, body}] = InventoryStub.calls()

      assert body == %{
               "warehouse_id" => InventoryClient.warehouse_id(),
               "shipment_date" => "2026-11-20",
               "external_slip_id" => slip.id,
               "operator" => scope.user.email,
               "lines" => [
                 %{
                   "item_id" => item.inventory_item_id,
                   "req_cases" => 0,
                   "req_pieces" => 36,
                   "min_expiration_date" => "2026-12-20"
                 }
               ]
             }
    end

    test "同じロットが複数回返されたら 1 行に合算する" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      body =
        allocated_order(slip, %{
          allocations: [{@lot1, "2026-12-20", 30}, {@lot1, "2026-12-20", 6}]
        })

      InventoryStub.routes([route_allocate(respond_json(201, body))])

      assert {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert [%{inventory_lot_id: @lot1, allocated_pieces: 36}] = allocated.allocated_lots
    end

    test "期限なしの商品のロットは 9999-12-31 のまま保存する" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      body = allocated_order(slip, %{allocations: [{@lot1, "9999-12-31", 36}]})
      InventoryStub.routes([route_allocate(respond_json(201, body))])

      assert {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert [lot] = allocated.allocated_lots
      assert SlipAllocatedLot.no_expiration?(lot)
    end

    test "在庫側の冪等な再送(200)も成功として扱う" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)
      InventoryStub.routes([route_allocate(respond_json(200, allocated_order(slip)))])

      assert {:ok, %{status: :allocated}, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    end
  end

  describe "allocate_shipping_slip/2: 在庫不足・エラー" do
    test "422 insufficient_stock は shortage で、不足数を保存する(入力は消えない)" do
      scope = staff_scope()
      slip = slip_fixture(%{client_slip_no: "PO-1"}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_cases" => 0, "shortage_pieces" => 7}]
          })
        end)
      ])

      assert {:ok, shortage, _} = ShippingSlips.allocate_shipping_slip(scope, slip)

      assert shortage.status == :shortage
      assert shortage.shortage_pieces == 7
      assert shortage.inventory_order_id == nil
      assert shortage.allocated_lots == []
      assert shortage.client_slip_no == "PO-1"
      assert shortage.total_piece_qty == 36
    end

    for {name, status, code, expected} <- [
          {"401", 401, "unauthorized", :unauthorized},
          {"404", 404, "not_found", :not_found}
        ] do
      test "#{name} #{code} は pending ＋ allocation_error = #{expected}(恒久)" do
        scope = staff_scope()
        slip = slip_fixture(%{}, scope)

        InventoryStub.routes([
          route_allocate(fn conn -> InventoryStub.error(conn, unquote(status), unquote(code)) end)
        ])

        assert {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
        assert pending.status == :pending
        assert pending.allocation_error == unquote(expected)
        refute ShippingSlip.transient_error?(pending.allocation_error)
        assert %DateTime{} = pending.allocation_attempted_at
      end
    end

    test "422 validation_failed は pending ＋ validation_failed で、errors を返す" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 422, "validation_failed", %{
            "errors" => [%{"path" => ["lines", 0, "item_id"], "message" => "は有効な商品ではありません"}]
          })
        end)
      ])

      assert {:ok, pending, %{errors: [%{path: ["lines", 0, "item_id"], message: _}]}} =
               ShippingSlips.allocate_shipping_slip(scope, slip)

      assert pending.status == :pending
      assert pending.allocation_error == :validation_failed
    end

    test "409 idempotency_conflict は pending ＋ idempotency_conflict で、既存のオーダー ID を保存する" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 409, "idempotency_conflict", %{
            "order_id" => @order_id,
            "status" => "allocated"
          })
        end)
      ])

      assert {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert pending.status == :pending
      assert pending.allocation_error == :idempotency_conflict
      assert pending.inventory_order_id == @order_id
    end

    test "通信失敗(リトライ後も)は pending ＋ connection(一時)で、入力内容は残る" do
      scope = staff_scope()
      slip = slip_fixture(%{client_slip_no: "PO-2"}, scope)

      InventoryStub.routes([route_allocate(&InventoryStub.timeout/1)])

      assert {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert pending.status == :pending
      assert pending.allocation_error == :connection
      assert ShippingSlip.transient_error?(pending.allocation_error)
      assert pending.client_slip_no == "PO-2"
      assert pending.total_piece_qty == 36
      assert %DateTime{} = pending.allocation_attempted_at
    end

    test "5xx も connection(一時)" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn -> InventoryStub.error(conn, 503, "unavailable") end)
      ])

      assert {:ok, %{status: :pending, allocation_error: :connection}, _} =
               ShippingSlips.allocate_shipping_slip(scope, slip)
    end

    test "引当合計が total_piece_qty と一致しなければ allocated にしない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      body = allocated_order(slip, %{allocations: [{@lot1, "2026-12-20", 35}]})
      InventoryStub.routes([route_allocate(respond_json(201, body))])

      assert {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)

      assert pending.status == :pending
      assert pending.allocation_error == :validation_failed

      # 在庫側に残ったオーダーは、次の再引当で解除できるよう ID を保存する。引当ロットは保存しない
      assert pending.inventory_order_id == @order_id
      assert pending.allocated_lots == []
    end

    test "引当済みでない応答・ケース引当を含む応答は allocated にしない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      body = allocated_order(slip, %{status: "cancelled"})
      InventoryStub.routes([route_allocate(respond_json(201, body))])

      assert {:ok, %{status: :pending, allocation_error: :validation_failed}, _} =
               ShippingSlips.allocate_shipping_slip(scope, slip)
    end
  end

  describe "allocate_shipping_slip/2: 再引当" do
    test "shortage の再引当で成功し、最低許容期限日を現在のルールで再計算する" do
      client = client_fixture()
      item = shipping_item_fixture()
      scope = staff_scope()
      slip = slip_fixture(%{client_id: client.id, shipping_item_id: item.id}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 36}]
          })
        end)
      ])

      assert {:ok, %{status: :shortage, min_expiration_date: nil} = shortage, _} =
               ShippingSlips.allocate_shipping_slip(scope, slip)

      InventoryStub.calls()

      # 入荷後(ルールを追加してから)再引当
      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 10
      })

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => []})),
        route_allocate(
          respond_json(201, allocated_order(shortage, %{min_expiration_date: "2026-11-30"}))
        )
      ])

      assert {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, shortage)

      assert allocated.status == :allocated
      assert allocated.shortage_pieces == nil
      assert allocated.min_expiration_date == ~D[2026-11-30]

      # 過去に API を呼んでいるので、先に照会する(解除するオーダーは無い)
      assert [{"GET", @orders, nil}, {"POST", @orders, body}] = InventoryStub.calls()
      assert hd(body["lines"])["min_expiration_date"] == "2026-11-30"
    end

    test "在庫側に引当済みのオーダーが残っていれば、照会 → 解除 → 引当の順で実行し、ロットを入れ替える" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      # 通信失敗: 在庫側では引当済みだが、応答を受け取れなかった
      InventoryStub.routes([route_allocate(&InventoryStub.timeout/1)])

      assert {:ok, %{status: :pending, allocation_error: :connection} = pending, _} =
               ShippingSlips.allocate_shipping_slip(scope, slip)

      InventoryStub.calls()
      stale = allocated_order(slip, %{order_id: "01JD0000000000000000000009"})
      fresh = allocated_order(slip, %{allocations: [{@lot2, "2026-12-30", 36}]})

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [stale]})),
        route_cancel(respond_json(200, Map.put(stale, "status", "cancelled"))),
        route_allocate(respond_json(201, fresh))
      ])

      assert {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, pending)

      assert allocated.status == :allocated
      assert allocated.inventory_order_id == @order_id

      assert [%{inventory_lot_id: @lot2, expiration_date: ~D[2026-12-30], allocated_pieces: 36}] =
               allocated.allocated_lots

      assert [
               {"GET", @orders, nil},
               {"POST", cancel_path, %{"operator" => operator, "reason" => "再引当のため"}},
               {"POST", @orders, _}
             ] = InventoryStub.calls()

      assert cancel_path == "#{@orders}/01JD0000000000000000000009/cancel"
      assert operator == scope.user.email
      assert length(lots_of(slip.id)) == 1
    end

    test "取消済みのオーダーは解除しない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)
      InventoryStub.routes([route_allocate(&InventoryStub.timeout/1)])
      {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      InventoryStub.calls()

      cancelled = Map.put(allocated_order(slip), "status", "cancelled")

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [cancelled]})),
        route_allocate(respond_json(201, allocated_order(slip)))
      ])

      assert {:ok, %{status: :allocated}, _} =
               ShippingSlips.allocate_shipping_slip(scope, pending)

      assert [{"GET", _, _}, {"POST", @orders, _}] = InventoryStub.calls()
    end

    test "解除に失敗したら pending のまま止まり、引当は呼ばない(旧オーダー・ロットは残す)" do
      scope = staff_scope()
      slip = allocated_slip(scope)
      assert slip.status == :allocated
      {:ok, changed} = ShippingSlips.update_shipping_slip(scope, slip, %{order_count: "2"})

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [allocated_order(slip)]})),
        route_cancel(&InventoryStub.timeout/1)
      ])

      assert {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, changed)

      assert pending.status == :pending
      assert pending.allocation_error == :connection
      assert pending.inventory_order_id == @order_id
      assert length(pending.allocated_lots) == 2
      refute Enum.any?(InventoryStub.calls(), &match?({"POST", @orders, _}, &1))

      # 復旧: 次の再引当で手順 2 からやり直し、解除 → 引当に成功する
      new_order = allocated_order(pending, %{order_id: "01JD0000000000000000000002"})

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [allocated_order(slip)]})),
        route_cancel(respond_json(200, Map.put(allocated_order(slip), "status", "cancelled"))),
        route_allocate(respond_json(201, new_order))
      ])

      assert {:ok, %{status: :allocated, inventory_order_id: "01JD0000000000000000000002"}, _} =
               ShippingSlips.allocate_shipping_slip(scope, pending)
    end

    test "在庫側がすでに出庫済みなら、再引当せず packed に突合する" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)
      InventoryStub.routes([route_allocate(&InventoryStub.timeout/1)])
      {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      InventoryStub.calls()

      shipped = allocated_order(slip, %{status: "shipped", shipped_at: "2026-11-19T01:02:03Z"})
      InventoryStub.routes([route_list(respond_json(200, %{"shipment_orders" => [shipped]}))])

      assert {:ok, packed, %{reconciled: true}} =
               ShippingSlips.allocate_shipping_slip(scope, pending)

      assert packed.status == :packed
      assert packed.inventory_order_id == @order_id
      assert packed.packed_by_user_id == scope.user.id
      assert packed.packed_at == ~U[2026-11-19 01:02:03Z]
      assert length(packed.allocated_lots) == 2
      assert [{"GET", @orders, nil}] = InventoryStub.calls()
    end

    test "pending / shortage 以外(引当済み・取消済みなど)は :invalid_status で、API を呼ばない" do
      scope = staff_scope()
      slip = allocated_slip(scope)

      assert {:error, :invalid_status} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert InventoryStub.calls() == []
    end

    test "viewer は拒否し、API を呼ばない" do
      slip = slip_fixture()

      assert {:error, :forbidden} = ShippingSlips.allocate_shipping_slip(viewer_scope(), slip)
      assert InventoryStub.calls() == []
      assert slip_row(slip.id).allocation_attempted_at == nil
    end

    test "対象倉庫が未設定なら API を呼ばず、状態も変えない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      without_warehouse(fn ->
        assert {:error, :warehouse_not_configured} =
                 ShippingSlips.allocate_shipping_slip(scope, slip)
      end)

      assert slip_row(slip.id).allocation_attempted_at == nil
    end

    test "API の呼び出し中に別の操作で状態が変わっていたら :stale で、結果を反映しない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          # 別の操作(取消など)が先に進んだことを再現する
          Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
            set: [
              status: :cancelled,
              cancelled_at: DateTime.utc_now(:second),
              cancelled_by_user_id: scope.user.id
            ]
          )

          InventoryStub.json(conn, 201, allocated_order(slip))
        end)
      ])

      assert {:error, :stale} = ShippingSlips.allocate_shipping_slip(scope, slip)

      row = slip_row(slip.id)
      assert row.status == :cancelled
      assert row.inventory_order_id == nil
      assert lots_of(slip.id) == []
    end
  end

  describe "update_shipping_slip/3" do
    test "引当済みの伝票の件数・出荷予定日を変更すると pending に戻り、数量を再計算する(旧引当は残す)" do
      client = client_fixture()
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})

      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 30
      })

      scope = staff_scope()
      slip = allocated_slip(scope, %{client_id: client.id, shipping_item_id: item.id})

      assert {:ok, changed} =
               ShippingSlips.update_shipping_slip(scope, slip, %{
                 "order_count" => "5",
                 "scheduled_ship_date" => "2026-11-25"
               })

      assert changed.status == :pending
      assert changed.order_count == 5
      assert changed.total_piece_qty == 60
      assert changed.box_count == 10
      assert changed.scheduled_ship_date == ~D[2026-11-25]
      assert changed.min_expiration_date == ~D[2026-12-25]
      assert changed.shortage_pieces == nil
      assert changed.allocation_error == nil
      # 旧オーダー・引当ロットは、旧引当の解除まで残す
      assert changed.inventory_order_id == @order_id
      assert length(changed.allocated_lots) == 2
    end

    test "箱数を指定すればその値を使う" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      assert {:ok, changed} =
               ShippingSlips.update_shipping_slip(scope, slip, %{
                 "order_count" => "2",
                 "box_count" => "9"
               })

      assert changed.box_count == 9
      assert changed.total_piece_qty == 24
    end

    test "shortage の伝票は不足数を消して pending に戻る" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 5}]
          })
        end)
      ])

      {:ok, shortage, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      assert shortage.shortage_pieces == 5

      assert {:ok, %{status: :pending, shortage_pieces: nil}} =
               ShippingSlips.update_shipping_slip(scope, shortage, %{"order_count" => "1"})
    end

    test "件数が不正なら changeset エラーで、伝票は変わらない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      assert {:error, changeset} =
               ShippingSlips.update_shipping_slip(scope, slip, %{"order_count" => "0"})

      assert Map.has_key?(errors_on(changeset), :order_count)
      assert slip_row(slip.id).order_count == 3
    end

    test "梱包済み・取消済みの伝票は変更できない" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
        set: [
          status: :cancelled,
          cancelled_at: DateTime.utc_now(:second),
          cancelled_by_user_id: scope.user.id
        ]
      )

      assert {:error, :invalid_status} =
               ShippingSlips.update_shipping_slip(scope, slip, %{"order_count" => "1"})

      assert slip_row(slip.id).order_count == 3
    end

    test "viewer は拒否し、対象倉庫が未設定なら変更しない" do
      slip = slip_fixture()

      assert {:error, :forbidden} =
               ShippingSlips.update_shipping_slip(viewer_scope(), slip, %{"order_count" => "1"})

      without_warehouse(fn ->
        assert {:error, :warehouse_not_configured} =
                 ShippingSlips.update_shipping_slip(staff_scope(), slip, %{"order_count" => "1"})
      end)

      assert slip_row(slip.id).order_count == 3
    end

    test "変更 → 再引当で、旧オーダーを解除してから新しい数量で引当する" do
      scope = staff_scope()
      slip = allocated_slip(scope)
      {:ok, changed} = ShippingSlips.update_shipping_slip(scope, slip, %{"order_count" => "1"})

      old = allocated_order(slip)
      new_id = "01JD0000000000000000000003"

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [old]})),
        route_cancel(respond_json(200, Map.put(old, "status", "cancelled"))),
        route_allocate(
          respond_json(
            201,
            allocated_order(changed, %{order_id: new_id, allocations: [{@lot1, "2026-12-20", 12}]})
          )
        )
      ])

      assert {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, changed)

      assert allocated.status == :allocated
      assert allocated.total_piece_qty == 12
      assert allocated.inventory_order_id == new_id
      assert [%{inventory_lot_id: @lot1, allocated_pieces: 12}] = allocated.allocated_lots

      assert [{"GET", _, _}, {"POST", _, _}, {"POST", @orders, body}] = InventoryStub.calls()
      assert hd(body["lines"])["req_pieces"] == 12
    end
  end

  describe "cancel_shipping_slip/2" do
    test "引当済みの伝票は、在庫側の引当を解除してから取消にする(実行者・日時を記録)" do
      scope = staff_scope()
      slip = allocated_slip(scope)
      order = allocated_order(slip)

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [order]})),
        route_cancel(respond_json(200, Map.put(order, "status", "cancelled")))
      ])

      assert {:ok, cancelled} = ShippingSlips.cancel_shipping_slip(scope, slip)

      assert cancelled.status == :cancelled
      assert cancelled.cancelled_by_user_id == scope.user.id
      assert %DateTime{} = cancelled.cancelled_at
      assert cancelled.inventory_order_id == nil
      assert cancelled.allocated_lots == []

      assert [
               {"GET", @orders, nil},
               {"POST", cancel_path, %{"operator" => operator, "reason" => _}}
             ] = InventoryStub.calls()

      assert cancel_path == "#{@orders}/#{@order_id}/cancel"
      assert operator == scope.user.email
    end

    test "在庫 API を一度も呼んでいない pending の伝票は、API を呼ばずに取消にする" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      assert {:ok, %{status: :cancelled}} = ShippingSlips.cancel_shipping_slip(scope, slip)
      assert InventoryStub.calls() == []
    end

    test "shortage の伝票は、照会して(解除するものが無ければ)取消にする" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)

      InventoryStub.routes([
        route_allocate(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 4}]
          })
        end)
      ])

      {:ok, shortage, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      InventoryStub.calls()

      InventoryStub.routes([route_list(respond_json(200, %{"shipment_orders" => []}))])

      assert {:ok, %{status: :cancelled, shortage_pieces: nil}} =
               ShippingSlips.cancel_shipping_slip(scope, shortage)

      assert [{"GET", @orders, nil}] = InventoryStub.calls()
    end

    test "通信失敗で未解除のオーダーが残っている pending は、照会で見つけて解除してから取消にする" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)
      InventoryStub.routes([route_allocate(&InventoryStub.timeout/1)])
      {:ok, pending, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      InventoryStub.calls()

      order = allocated_order(slip)

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [order]})),
        route_cancel(respond_json(200, Map.put(order, "status", "cancelled")))
      ])

      assert {:ok, %{status: :cancelled}} = ShippingSlips.cancel_shipping_slip(scope, pending)
      assert [{"GET", _, _}, {"POST", _, _}] = InventoryStub.calls()
    end

    test "解除に失敗したら、ローカルは変えず(引当済みのまま)エラーを返し、再度取消できる" do
      scope = staff_scope()
      slip = allocated_slip(scope)
      order = allocated_order(slip)

      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [order]})),
        route_cancel(&InventoryStub.timeout/1)
      ])

      assert {:error, :connection} = ShippingSlips.cancel_shipping_slip(scope, slip)

      row = slip_row(slip.id)
      assert row.status == :allocated
      assert row.inventory_order_id == @order_id
      assert row.cancelled_at == nil
      assert length(lots_of(slip.id)) == 2

      # 復旧後にやり直せる
      InventoryStub.routes([
        route_list(respond_json(200, %{"shipment_orders" => [order]})),
        route_cancel(respond_json(200, Map.put(order, "status", "cancelled")))
      ])

      assert {:ok, %{status: :cancelled}} =
               ShippingSlips.cancel_shipping_slip(scope, slip_row(slip.id))
    end

    test "照会に失敗した場合も、ローカルは変えない" do
      scope = staff_scope()
      slip = allocated_slip(scope)

      InventoryStub.routes([
        route_list(fn conn -> InventoryStub.error(conn, 401, "unauthorized") end)
      ])

      assert {:error, :unauthorized} = ShippingSlips.cancel_shipping_slip(scope, slip)
      assert slip_row(slip.id).status == :allocated
    end

    test "在庫側がすでに出庫済みなら取消できない(ローカルは変えない)" do
      scope = staff_scope()
      slip = allocated_slip(scope)
      shipped = allocated_order(slip, %{status: "shipped", shipped_at: "2026-11-19T01:02:03Z"})

      InventoryStub.routes([route_list(respond_json(200, %{"shipment_orders" => [shipped]}))])

      assert {:error, {:remote_state, :shipped}} = ShippingSlips.cancel_shipping_slip(scope, slip)
      assert slip_row(slip.id).status == :allocated
    end

    test "取消済みの伝票は、同じ発注元伝票番号で登録し直せる" do
      scope = staff_scope()
      client = client_fixture()
      item = shipping_item_fixture()
      attrs = %{client_id: client.id, shipping_item_id: item.id, client_slip_no: "PO-1"}
      slip = slip_fixture(attrs, scope)

      assert {:ok, %{status: :cancelled}} = ShippingSlips.cancel_shipping_slip(scope, slip)
      assert slip_fixture(attrs, scope)
    end

    test "梱包済み・取消済みの伝票は取消できない(:invalid_status。API は呼ばない)" do
      scope = staff_scope()
      slip = slip_fixture(%{}, scope)
      {:ok, cancelled} = ShippingSlips.cancel_shipping_slip(scope, slip)

      assert {:error, :invalid_status} = ShippingSlips.cancel_shipping_slip(scope, cancelled)

      other = slip_fixture(%{}, scope)

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^other.id),
        set: [
          status: :packed,
          inventory_order_id: @order_id,
          packed_at: DateTime.utc_now(:second),
          packed_by_user_id: scope.user.id
        ]
      )

      assert {:error, :invalid_status} = ShippingSlips.cancel_shipping_slip(scope, other)
      assert InventoryStub.calls() == []
    end

    test "viewer は拒否する" do
      slip = slip_fixture()

      assert {:error, :forbidden} = ShippingSlips.cancel_shipping_slip(viewer_scope(), slip)
      assert slip_row(slip.id).status == :pending
    end
  end

  describe "summarize_ship_dates/1" do
    test "出荷予定日ごとの残件数(pending・allocated・shortage)を日付順に返す" do
      scope = staff_scope()
      slip_fixture(%{scheduled_ship_date: ~D[2026-11-21]}, scope)
      slip_fixture(%{scheduled_ship_date: ~D[2026-11-21]}, scope)
      allocated_slip(scope, %{scheduled_ship_date: ~D[2026-11-20]})
      slip_fixture(%{scheduled_ship_date: ~D[2026-11-10]}, scope)

      assert [
               %{date: ~D[2026-11-20], remaining: 1},
               %{date: ~D[2026-11-21], remaining: 2}
             ] = ShippingSlips.summarize_ship_dates(~D[2026-11-15])
    end

    test "梱包済みは残件数に数えず、取消済みだけの日付は出さない" do
      scope = staff_scope()
      packed = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      cancelled = slip_fixture(%{scheduled_ship_date: ~D[2026-11-22]}, scope)
      {:ok, _} = ShippingSlips.cancel_shipping_slip(scope, cancelled)

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^packed.id),
        set: [
          status: :packed,
          inventory_order_id: @order_id,
          packed_at: DateTime.utc_now(:second),
          packed_by_user_id: scope.user.id
        ]
      )

      assert [%{date: ~D[2026-11-20], remaining: 0}] =
               ShippingSlips.summarize_ship_dates(~D[2026-11-15])
    end
  end

  describe "list_shipping_slips/2" do
    test "出荷予定日の伝票を slip_no 順に返し、フィルタで絞れる" do
      scope = staff_scope()
      pending = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      allocated = allocated_slip(scope, %{scheduled_ship_date: ~D[2026-11-20]})
      cancelled = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      {:ok, _} = ShippingSlips.cancel_shipping_slip(scope, cancelled)
      other_day = slip_fixture(%{scheduled_ship_date: ~D[2026-11-21]}, scope)

      ids = fn slips -> Enum.map(slips, & &1.id) end

      assert ids.(ShippingSlips.list_shipping_slips(~D[2026-11-20])) ==
               [pending.id, allocated.id, cancelled.id]

      assert ids.(ShippingSlips.list_shipping_slips(~D[2026-11-20], :unpacked)) ==
               [pending.id, allocated.id]

      refute other_day.id in ids.(ShippingSlips.list_shipping_slips(~D[2026-11-20]))
      assert ShippingSlips.list_shipping_slips(~D[2026-11-20], :shortage) == []
    end

    test "発注元・商品・引当ロットを preload する" do
      scope = staff_scope()
      slip = allocated_slip(scope, %{scheduled_ship_date: ~D[2026-11-20]})

      assert [found] = ShippingSlips.list_shipping_slips(~D[2026-11-20])
      assert found.id == slip.id
      assert found.client.id == slip.client_id
      assert found.shipping_item.id == slip.shipping_item_id
      assert length(found.allocated_lots) == 2
    end
  end

  describe "get_shipping_slip!/1" do
    test "発注元・発送商品・引当ロット(期限日順)を preload して返す" do
      scope = staff_scope()
      slip = allocated_slip(scope)

      found = ShippingSlips.get_shipping_slip!(slip.id)
      assert found.client.id == slip.client_id
      assert found.shipping_item.id == slip.shipping_item_id

      assert [~D[2026-12-20], ~D[2026-12-25]] =
               Enum.map(found.allocated_lots, & &1.expiration_date)
    end

    test "存在しなければ例外" do
      assert_raise Ecto.NoResultsError, fn ->
        ShippingSlips.get_shipping_slip!(Ecto.ULID.generate())
      end
    end
  end

  describe "ExpirationRules との整合" do
    test "ルールを後から削除しても、引当済みの伝票の最低許容期限日は変わらない" do
      client = client_fixture()
      item = shipping_item_fixture()

      rule =
        expiration_rule_fixture(%{
          client_id: client.id,
          shipping_item_id: item.id,
          min_remaining_days: 30
        })

      scope = staff_scope()
      slip = allocated_slip(scope, %{client_id: client.id, shipping_item_id: item.id})

      {:ok, _} = ExpirationRules.delete_expiration_rule(user_scope_fixture(), rule)

      assert slip_row(slip.id).min_expiration_date == ~D[2026-12-20]
    end
  end

  # 対象倉庫の設定を一時的に外す
  defp without_warehouse(fun) do
    previous = Application.get_env(:food_ship, InventoryClient)
    Application.put_env(:food_ship, InventoryClient, Keyword.put(previous, :warehouse_id, nil))

    try do
      fun.()
    after
      Application.put_env(:food_ship, InventoryClient, previous)
    end
  end
end
