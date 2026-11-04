defmodule FoodVaultWeb.Api.V1.ShipmentOrderControllerTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Inventories, Items, Repo, ShipmentOrders}
  alias FoodVault.Inventories.{InventoryLot, InventoryTransaction}
  alias FoodVault.ShipmentOrders.{ShipmentOrder, ShipmentOrderEvent}

  @path "/api/v1/shipment_orders"

  setup do
    item = item_fixture(%{units_per_case: 12})
    lot = lot_fixture(%{item_id: item.id, case_qty: 5, expiration_date: ~D[2027-01-31]})

    %{item: item, lot: lot, warehouse_id: lot.warehouse_id}
  end

  defp body(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "warehouse_id" => ctx.warehouse_id,
        "shipment_date" => "2026-11-15",
        "external_slip_id" => "SLIP-1",
        "operator" => "staff@example.com",
        "lines" => [%{"item_id" => ctx.item.id, "req_cases" => 1, "req_pieces" => 3}]
      },
      extra
    )
  end

  defp post_json(conn, path, body), do: post(conn, path, Jason.encode!(body))

  describe "認証" do
    test "トークンなしは全エンドポイントで 401" do
      order = FoodVault.ShipmentOrdersFixtures.order_fixture()

      for conn <- [
            post(unauthenticated_api_conn(), @path, "{}"),
            get(unauthenticated_api_conn(), "#{@path}/#{order.id}"),
            get(unauthenticated_api_conn(), "#{@path}?external_slip_id=X")
          ] do
        assert %{"error" => "unauthorized", "message" => _} = json_response(conn, 401)
      end
    end

    test "不正なトークンは 401、2 つ目の登録トークンは通る", %{} do
      conn = get(api_conn("wrong"), "#{@path}?external_slip_id=X")
      assert %{"error" => "unauthorized"} = json_response(conn, 401)

      conn = get(api_conn("test-inventory-api-token-2"), "#{@path}?external_slip_id=X")
      assert %{"shipment_orders" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/shipment_orders (① 出庫引当)" do
    test "201 でオーダー表現(引当ロット付き)を返し、DB に保存する", ctx do
      conn = post_json(api_conn(), @path, body(ctx))

      assert %{
               "order_id" => order_id,
               "external_slip_id" => "SLIP-1",
               "warehouse_id" => warehouse_id,
               "shipment_date" => "2026-11-15",
               "status" => "allocated",
               "shipped_at" => nil,
               "lines" => [line]
             } = json_response(conn, 201)

      assert warehouse_id == ctx.warehouse_id
      assert line["item_id"] == ctx.item.id
      assert line["req_cases"] == 1 and line["req_pieces"] == 3
      assert line["min_expiration_date"] == nil

      # 1 ケース + 3 バラ: 5 ケースのロットから 1 ケースとバラ 3(荷崩し 1 ケース)を引き当てる
      assert [allocation] = line["allocations"]
      assert allocation["lot_id"] == ctx.lot.id
      assert allocation["expiration_date"] == "2027-01-31"
      assert allocation["allocated_cases"] == 1
      assert allocation["allocated_pieces"] == 3

      order = ShipmentOrders.get_shipment_order!(order_id)
      assert order.status == :allocated
      assert [%{event_type: :created, operator: "staff@example.com", user_id: nil}] = order.events
    end

    test "min_expiration_date を受け付け、応答に含める", ctx do
      lines = [
        %{
          "item_id" => ctx.item.id,
          "req_cases" => 1,
          "req_pieces" => 0,
          "min_expiration_date" => "2027-01-01"
        }
      ]

      conn = post_json(api_conn(), @path, body(ctx, %{"lines" => lines}))

      assert %{"lines" => [%{"min_expiration_date" => "2027-01-01"}]} = json_response(conn, 201)
    end

    test "external_slip_id の再送(内容が一致)は 200 で既存を返し、履歴を増やさない", ctx do
      first = json_response(post_json(api_conn(), @path, body(ctx)), 201)
      second = json_response(post_json(api_conn(), @path, body(ctx)), 200)

      assert second == first
      assert Repo.aggregate(ShipmentOrder, :count) == 1
      assert Repo.aggregate(ShipmentOrderEvent, :count) == 1
    end

    test "external_slip_id の内容が違えば 409 idempotency_conflict(order_id・status 付き)", ctx do
      %{"order_id" => order_id} = json_response(post_json(api_conn(), @path, body(ctx)), 201)

      changed =
        body(ctx, %{"lines" => [%{"item_id" => ctx.item.id, "req_cases" => 2, "req_pieces" => 0}]})

      conn = post_json(api_conn(), @path, changed)

      assert %{
               "error" => "idempotency_conflict",
               "message" => _,
               "order_id" => ^order_id,
               "status" => "allocated"
             } = json_response(conn, 409)

      assert Repo.aggregate(ShipmentOrder, :count) == 1
    end

    test "取消済みの external_slip_id は新しいオーダーとして引き当てられる", ctx do
      %{"order_id" => first_id} = json_response(post_json(api_conn(), @path, body(ctx)), 201)
      {:ok, order} = ShipmentOrders.fetch_shipment_order(first_id)
      {:ok, _} = ShipmentOrders.cancel_shipment_order({:api, "x"}, order)

      assert %{"order_id" => second_id} =
               json_response(post_json(api_conn(), @path, body(ctx)), 201)

      refute second_id == first_id
    end

    test "external_slip_id が無くても引き当てられる", ctx do
      conn = post_json(api_conn(), @path, Map.delete(body(ctx), "external_slip_id"))

      assert %{"external_slip_id" => nil, "status" => "allocated"} = json_response(conn, 201)
    end

    test "在庫不足は 422 insufficient_stock で、全明細分の shortages を返し DB は変わらない", ctx do
      other = item_fixture(%{units_per_case: 6})
      lot_fixture(%{warehouse_id: ctx.warehouse_id, item_id: other.id, case_qty: 0, piece_qty: 4})

      lines = [
        %{"item_id" => ctx.item.id, "req_cases" => 6, "req_pieces" => 0},
        %{"item_id" => other.id, "req_cases" => 0, "req_pieces" => 5}
      ]

      conn = post_json(api_conn(), @path, body(ctx, %{"lines" => lines}))

      assert %{"error" => "insufficient_stock", "message" => _, "shortages" => shortages} =
               json_response(conn, 422)

      assert Enum.sort_by(shortages, & &1["item_id"]) ==
               Enum.sort_by(
                 [
                   %{"item_id" => ctx.item.id, "shortage_cases" => 1, "shortage_pieces" => 0},
                   %{"item_id" => other.id, "shortage_cases" => 0, "shortage_pieces" => 1}
                 ],
                 & &1["item_id"]
               )

      assert Repo.aggregate(ShipmentOrder, :count) == 0
      assert Repo.get!(InventoryLot, ctx.lot.id).allocated_case_qty == 0
    end

    test "operator が無い・空・長すぎる・文字列でないは 422 validation_failed", ctx do
      for bad <- [nil, "", "   ", String.duplicate("a", 256), 123] do
        params =
          if bad == nil,
            do: Map.delete(body(ctx), "operator"),
            else: body(ctx, %{"operator" => bad})

        conn = post_json(api_conn(), @path, params)

        assert %{"error" => "validation_failed", "errors" => [%{"path" => ["operator"]}]} =
                 json_response(conn, 422)
      end

      assert Repo.aggregate(ShipmentOrder, :count) == 0
    end

    test "255 文字の operator は受け付ける", ctx do
      operator = String.duplicate("a", 255)
      conn = post_json(api_conn(), @path, body(ctx, %{"operator" => operator}))

      assert %{"order_id" => order_id} = json_response(conn, 201)
      assert [%{operator: ^operator}] = ShipmentOrders.get_shipment_order!(order_id).events
    end

    test "入力不正は 422 validation_failed で項目別の errors を返す", ctx do
      cases = [
        {%{"lines" => []}, ["lines"]},
        {%{"lines" => [%{"item_id" => ctx.item.id, "req_cases" => -1, "req_pieces" => 0}]},
         ["lines", 0, "req_cases"]},
        {%{"lines" => [%{"item_id" => "not-a-ulid", "req_cases" => 1, "req_pieces" => 0}]},
         ["lines", 0, "item_id"]},
        {%{"warehouse_id" => "not-a-ulid"}, ["warehouse_id"]},
        {%{"shipment_date" => "2026/11/15"}, ["shipment_date"]},
        {%{"lines" => "none"}, ["lines"]}
      ]

      for {change, path} <- cases do
        conn = post_json(api_conn(), @path, body(ctx, change))

        assert %{"error" => "validation_failed", "errors" => errors} = json_response(conn, 422)
        assert Enum.any?(errors, &(&1["path"] == path and is_binary(&1["message"])))
      end

      assert Repo.aggregate(ShipmentOrder, :count) == 0
    end

    test "存在しない・アーカイブ済みの商品と倉庫は 422 validation_failed", ctx do
      unknown = Ecto.ULID.generate()

      conn = post_json(api_conn(), @path, body(ctx, %{"warehouse_id" => unknown}))
      assert %{"error" => "validation_failed"} = json_response(conn, 422)

      archived = item_fixture()
      scope = FoodVault.AccountsFixtures.user_scope_fixture()
      {:ok, _} = Items.archive_item(scope, archived)
      lines = [%{"item_id" => archived.id, "req_cases" => 1, "req_pieces" => 0}]

      conn = post_json(api_conn(), @path, body(ctx, %{"lines" => lines}))

      assert %{"error" => "validation_failed", "errors" => [%{"path" => ["lines", 0, "item_id"]}]} =
               json_response(conn, 422)
    end

    test "壊れた JSON は 500 でなく JSON の 400", %{} do
      {400, _headers, response} =
        assert_error_sent(400, fn -> post(api_conn(), @path, "{broken") end)

      assert %{"error" => "bad_request", "message" => _} = Jason.decode!(response)
    end

    test "JSON が配列・空ボディでも 500 にならず 422", %{} do
      assert %{"error" => "validation_failed"} = json_response(post(api_conn(), @path, "[]"), 422)
      assert %{"error" => "validation_failed"} = json_response(post(api_conn(), @path, "{}"), 422)
    end

    test "Accept ヘッダが無くても、エラーは JSON で返る", %{} do
      {400, headers, response} =
        assert_error_sent(400, fn ->
          Phoenix.ConnTest.build_conn()
          |> put_req_header("authorization", "Bearer test-inventory-api-token")
          |> put_req_header("content-type", "application/json")
          |> post(@path, "{broken")
        end)

      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert %{"error" => "bad_request"} = Jason.decode!(response)
    end
  end

  describe "GET /api/v1/shipment_orders/:id (⑤ 照会)" do
    test "200 でオーダー表現を返す", ctx do
      %{"order_id" => order_id} =
        created = json_response(post_json(api_conn(), @path, body(ctx)), 201)

      assert json_response(get(api_conn(), "#{@path}/#{order_id}"), 200) == created
    end

    test "存在しない ID と ULID 形式でない ID は 404 not_found", %{} do
      for id <- [Ecto.ULID.generate(), "not-a-ulid", "123"] do
        assert %{"error" => "not_found", "message" => _} =
                 json_response(get(api_conn(), "#{@path}/#{id}"), 404)
      end
    end
  end

  describe "GET /api/v1/shipment_orders?external_slip_id= (⑤ 照会)" do
    test "取消済みを含め、新しい順に返す", ctx do
      %{"order_id" => first_id} = json_response(post_json(api_conn(), @path, body(ctx)), 201)
      {:ok, first} = ShipmentOrders.fetch_shipment_order(first_id)
      {:ok, _} = ShipmentOrders.cancel_shipment_order({:api, "x"}, first)
      %{"order_id" => second_id} = json_response(post_json(api_conn(), @path, body(ctx)), 201)

      conn = get(api_conn(), "#{@path}?external_slip_id=SLIP-1")

      assert %{"shipment_orders" => [newest, oldest]} = json_response(conn, 200)
      assert newest["order_id"] == second_id and newest["status"] == "allocated"
      assert oldest["order_id"] == first_id and oldest["status"] == "cancelled"
      # 引当解除後も引当明細は残る
      assert [%{"allocations" => [_]}] = oldest["lines"]
    end

    test "該当なしは空配列で 200", %{} do
      conn = get(api_conn(), "#{@path}?external_slip_id=NOPE")

      assert json_response(conn, 200) == %{"shipment_orders" => []}
    end

    test "パラメータなし・空は 422 validation_failed", %{} do
      for query <- ["", "?external_slip_id=", "?external_slip_id=%20", "?other=1"] do
        conn = get(api_conn(), @path <> query)

        assert %{"error" => "validation_failed", "errors" => [%{"path" => ["external_slip_id"]}]} =
                 json_response(conn, 422)
      end
    end

    test "256 文字以上は 422 validation_failed", %{} do
      conn = get(api_conn(), "#{@path}?external_slip_id=#{String.duplicate("a", 256)}")

      assert %{"error" => "validation_failed"} = json_response(conn, 422)
    end

    test "external_slip_id が配列などの文字列でない値でも 422", %{} do
      conn = get(api_conn(), "#{@path}?external_slip_id[]=a")

      assert %{"error" => "validation_failed"} = json_response(conn, 422)
    end
  end

  describe "ルーティング" do
    test "存在しないルートと reverse(段階 5)は JSON の 404" do
      order_id = Ecto.ULID.generate()

      for {method, path} <- [
            {:get, "/api/v1/unknown"},
            {:post, "#{@path}/#{order_id}/reverse"},
            {:get, "/api/unknown"}
          ] do
        conn = dispatch(api_conn(), FoodVaultWeb.Endpoint, method, path, nil)

        assert %{"error" => "not_found", "message" => _} = json_response(conn, 404)
      end
    end

    test "Accept が無くても存在しないルートは JSON の 404" do
      conn = get(Phoenix.ConnTest.build_conn(), "/api/v1/unknown")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "ブラウザ(Accept: text/html)のエラーは HTML のまま" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "text/html")
        |> get("/no-such-page")

      assert response(conn, 404)
      assert [content_type | _] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
    end
  end

  describe "受払履歴・在庫への影響" do
    test "引当しても現在庫は減らず、引当済数だけが増える", ctx do
      json_response(post_json(api_conn(), @path, body(ctx)), 201)

      lot = Inventories.get_inventory_lot!(ctx.lot.id)

      # 荷崩し 1 ケース: ケース 5 → 4、バラ 0 → 12。引当はケース 1 + バラ 3
      assert {lot.case_qty, lot.piece_qty} == {4, 12}
      assert {lot.allocated_case_qty, lot.allocated_piece_qty} == {1, 3}

      assert Repo.aggregate(InventoryTransaction, :count, :id) >= 1
    end
  end
end
