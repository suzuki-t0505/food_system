defmodule FoodShip.Inventory.ClientTest do
  # ログのレベルを変更するため async: false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FoodShip.Inventory.Client
  alias FoodShip.InventoryStub

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  @params %{
    warehouse_id: "01JA0000000000000000000000",
    shipment_date: ~D[2026-11-15],
    external_slip_id: "01JB0000000000000000000001",
    operator: "staff@example.com",
    lines: [
      %{
        item_id: "01JC0000000000000000000001",
        req_cases: 0,
        req_pieces: 3,
        min_expiration_date: ~D[2026-12-15]
      }
    ]
  }

  # リクエストの内容をテストプロセスへ送って検証できるようにする
  defp reporting(response_fun) do
    pid = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(pid, {
        :request,
        %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          authorization: Plug.Conn.get_req_header(conn, "authorization"),
          body: if(body == "", do: nil, else: Jason.decode!(body))
        }
      })

      response_fun.(conn)
    end
  end

  describe "allocate/1" do
    test "201 でオーダー(引当ロット付き)を返し、リクエストに operator とトークンが付く" do
      InventoryStub.stub(
        reporting(fn conn ->
          InventoryStub.json(conn, 201, InventoryStub.order(%{min_expiration_date: "2026-12-15"}))
        end)
      )

      assert {:ok, order, :created} = Client.allocate(@params)

      assert order.order_id == "01JD0000000000000000000001"
      assert order.status == :allocated
      assert order.shipment_date == ~D[2026-11-15]

      assert [%{min_expiration_date: ~D[2026-12-15], allocations: [allocation]}] = order.lines
      assert allocation.expiration_date == ~D[2026-12-20]
      assert allocation.allocated_pieces == 3
      assert allocation.allocated_cases == 0

      assert_received {:request, request}
      assert request.method == "POST"
      assert request.path == "/api/v1/shipment_orders"
      assert request.authorization == ["Bearer test-inventory-api-token"]

      assert request.body == %{
               "warehouse_id" => "01JA0000000000000000000000",
               "shipment_date" => "2026-11-15",
               "external_slip_id" => "01JB0000000000000000000001",
               "operator" => "staff@example.com",
               "lines" => [
                 %{
                   "item_id" => "01JC0000000000000000000001",
                   "req_cases" => 0,
                   "req_pieces" => 3,
                   "min_expiration_date" => "2026-12-15"
                 }
               ]
             }
    end

    test "200 は冪等な再送(:replayed)" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, InventoryStub.order()) end)

      assert {:ok, %{status: :allocated}, :replayed} = Client.allocate(@params)
    end

    test "最低許容期限日なしは null で送る" do
      InventoryStub.stub(
        reporting(fn conn -> InventoryStub.json(conn, 201, InventoryStub.order()) end)
      )

      params = put_in(@params, [:lines, Access.at(0), :min_expiration_date], nil)
      assert {:ok, _order, :created} = Client.allocate(params)

      assert_received {:request, %{body: %{"lines" => [%{"min_expiration_date" => nil}]}}}
    end

    test "422 insufficient_stock は不足を返す" do
      InventoryStub.stub(fn conn ->
        InventoryStub.error(conn, 422, "insufficient_stock", %{
          "shortages" => [
            %{
              "item_id" => "01JC0000000000000000000001",
              "shortage_cases" => 0,
              "shortage_pieces" => 2
            }
          ]
        })
      end)

      assert {:error, :insufficient_stock,
              [%{item_id: "01JC0000000000000000000001", shortage_cases: 0, shortage_pieces: 2}]} =
               Client.allocate(@params)
    end

    test "422 validation_failed は errors を返す" do
      InventoryStub.stub(fn conn ->
        InventoryStub.error(conn, 422, "validation_failed", %{
          "errors" => [%{"path" => ["lines", 0, "item_id"], "message" => "は有効な商品ではありません"}]
        })
      end)

      assert {:error, :validation_failed,
              [%{path: ["lines", 0, "item_id"], message: "は有効な商品ではありません"}]} =
               Client.allocate(@params)
    end

    test "409 idempotency_conflict は既存の order_id と status を返す" do
      InventoryStub.stub(fn conn ->
        InventoryStub.error(conn, 409, "idempotency_conflict", %{
          "order_id" => "01JD0000000000000000000009",
          "status" => "allocated"
        })
      end)

      assert {:error, :idempotency_conflict,
              %{order_id: "01JD0000000000000000000009", status: :allocated}} =
               Client.allocate(@params)
    end

    test "401 は :unauthorized、404 は :not_found(リトライしない)" do
      Req.Test.expect(Client, 1, fn conn -> InventoryStub.error(conn, 401, "unauthorized") end)
      assert {:error, :unauthorized} = Client.allocate(@params)

      Req.Test.expect(Client, 1, fn conn -> InventoryStub.error(conn, 404, "not_found") end)
      assert {:error, :not_found} = Client.allocate(@params)
    end

    test "本文が想定外なら :connection" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 201, %{"unexpected" => true}) end)
      assert {:error, :connection} = Client.allocate(@params)

      InventoryStub.stub(fn conn ->
        InventoryStub.json(conn, 201, InventoryStub.order(%{status: "unknown"}))
      end)

      assert {:error, :connection} = Client.allocate(@params)
    end
  end

  describe "リトライ" do
    test "5xx は 3 回までリトライし(計 4 回)、失敗したら :connection" do
      Req.Test.expect(Client, 4, fn conn -> InventoryStub.error(conn, 503, "unavailable") end)

      assert {:error, :connection} = Client.allocate(@params)
    end

    test "リトライの途中で成功すれば成功を返す" do
      Req.Test.expect(Client, fn conn -> InventoryStub.error(conn, 502, "bad_gateway") end)
      Req.Test.expect(Client, fn conn -> InventoryStub.error(conn, 500, "oops") end)
      Req.Test.expect(Client, fn conn -> InventoryStub.json(conn, 201, InventoryStub.order()) end)

      assert {:ok, %{status: :allocated}, :created} = Client.allocate(@params)
    end

    test "タイムアウトも POST でリトライし、続けば :connection" do
      Req.Test.expect(Client, 4, &InventoryStub.timeout/1)

      assert {:error, :connection} = Client.allocate(@params)
    end

    test "4xx(409・422)はリトライしない" do
      Req.Test.expect(Client, 1, fn conn -> InventoryStub.error(conn, 409, "invalid_state") end)

      assert {:error, :invalid_state} =
               Client.ship_order("01JD0000000000000000000001", "a@example.com")

      Req.Test.expect(Client, 1, fn conn ->
        InventoryStub.error(conn, 422, "validation_failed")
      end)

      assert {:error, :validation_failed, []} = Client.allocate(@params)
    end
  end

  describe "ship_order/2" do
    test "出庫確定(operator を付ける)" do
      InventoryStub.stub(
        reporting(fn conn ->
          InventoryStub.json(
            conn,
            200,
            InventoryStub.order(%{status: "shipped", shipped_at: "2026-11-15T03:04:05Z"})
          )
        end)
      )

      assert {:ok, %{status: :shipped, shipped_at: ~U[2026-11-15 03:04:05Z]}} =
               Client.ship_order("01JD0000000000000000000001", "staff@example.com")

      assert_received {:request, request}
      assert request.method == "POST"
      assert request.path == "/api/v1/shipment_orders/01JD0000000000000000000001/ship"
      assert request.body == %{"operator" => "staff@example.com"}
    end
  end

  describe "cancel_order/3" do
    test "引当解除(reason は指定したときだけ送る)" do
      InventoryStub.stub(
        reporting(fn conn ->
          InventoryStub.json(conn, 200, InventoryStub.order(%{status: "cancelled"}))
        end)
      )

      assert {:ok, %{status: :cancelled}} =
               Client.cancel_order("01JD0000000000000000000001", "staff@example.com")

      assert_received {:request, %{path: path, body: body}}
      assert path == "/api/v1/shipment_orders/01JD0000000000000000000001/cancel"
      assert body == %{"operator" => "staff@example.com"}

      assert {:ok, _order} =
               Client.cancel_order("01JD0000000000000000000001", "staff@example.com", "再引当のため")

      assert_received {:request, %{body: body}}
      assert body == %{"operator" => "staff@example.com", "reason" => "再引当のため"}
    end
  end

  describe "get_order/1" do
    test "オーダーを照会する" do
      InventoryStub.stub(
        reporting(fn conn -> InventoryStub.json(conn, 200, InventoryStub.order()) end)
      )

      assert {:ok, %{order_id: "01JD0000000000000000000001"}} =
               Client.get_order("01JD0000000000000000000001")

      assert_received {:request,
                       %{
                         method: "GET",
                         path: "/api/v1/shipment_orders/01JD0000000000000000000001"
                       }}
    end

    test "存在しなければ :not_found" do
      InventoryStub.stub(fn conn -> InventoryStub.error(conn, 404, "not_found") end)

      assert {:error, :not_found} = Client.get_order("01JD0000000000000000000001")
    end
  end

  describe "list_orders_by_slip/1" do
    test "external_slip_id で照会し、複数件を返す" do
      InventoryStub.stub(
        reporting(fn conn ->
          InventoryStub.json(conn, 200, %{
            "shipment_orders" => [
              InventoryStub.order(%{order_id: "01JD0000000000000000000002"}),
              InventoryStub.order(%{status: "cancelled"})
            ]
          })
        end)
      )

      assert {:ok, [%{order_id: "01JD0000000000000000000002"}, %{status: :cancelled}]} =
               Client.list_orders_by_slip("01JB0000000000000000000001")

      assert_received {:request, request}
      assert request.path == "/api/v1/shipment_orders"
      assert request.query == "external_slip_id=01JB0000000000000000000001"
    end

    test "該当なしは空のリスト" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end)

      assert {:ok, []} = Client.list_orders_by_slip("01JB0000000000000000000001")
    end

    test "本文が想定外なら :connection" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"other" => 1}) end)

      assert {:error, :connection} = Client.list_orders_by_slip("01JB0000000000000000000001")
    end
  end

  describe "find_item/1" do
    @items %{
      "items" => [
        %{
          "id" => "01JC0000000000000000000001",
          "item_code" => "4901",
          "item_name" => "商品A",
          "maker_id" => "01JF0000000000000000000001",
          "maker_name" => "メーカーX",
          "units_per_case" => 12,
          "expiration_type" => "best_before"
        },
        %{"id" => "01JC0000000000000000000002", "item_code" => "49011", "item_name" => "商品B"}
      ]
    }

    test "商品コードの完全一致を返す" do
      InventoryStub.stub(reporting(fn conn -> InventoryStub.json(conn, 200, @items) end))

      assert {:ok,
              %{
                id: "01JC0000000000000000000001",
                item_name: "商品A",
                maker_id: "01JF0000000000000000000001",
                maker_name: "メーカーX"
              }} = Client.find_item("4901")

      assert_received {:request, %{query: "item_code=4901", path: "/api/v1/items"}}
    end

    test "一致する商品が無ければ :not_found" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, @items) end)

      assert {:error, :not_found} = Client.find_item("9999")
    end

    test "401 は :unauthorized" do
      InventoryStub.stub(fn conn -> InventoryStub.error(conn, 401, "unauthorized") end)

      assert {:error, :unauthorized} = Client.find_item("4901")
    end
  end

  describe "warehouse_id/0" do
    test "設定値を返す" do
      assert Client.warehouse_id() == "01JA0000000000000000000000"
    end
  end

  describe "ログ" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "呼び出しを :api カテゴリで記録し、トークンを出さない" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 201, InventoryStub.order()) end)

      log = capture_log(fn -> Client.allocate(@params) end)

      assert log =~ "在庫 API を呼び出しました。"
      assert log =~ "API"
      refute log =~ "test-inventory-api-token"
      refute log =~ "Bearer"
    end

    test "通信失敗も記録するが、トークンは出さない" do
      InventoryStub.stub(&InventoryStub.timeout/1)

      log = capture_log(fn -> Client.allocate(@params) end)

      assert log =~ "在庫 API に接続できませんでした。"
      refute log =~ "test-inventory-api-token"
    end
  end
end
