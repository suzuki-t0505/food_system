defmodule FoodShipWeb.ShippingSlipLive.FormTest do
  # Task から Req.Test・DB を使うため async: false(共有モード)
  use FoodShipWeb.ConnCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.ShippingSlipsFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias FoodShip.{InventoryStub, Repo, ShippingSlips}
  alias FoodShip.ShippingSlips.ShippingSlip

  setup {Req.Test, :set_req_test_from_context}

  # 画面の表示・伝票の作成では、在庫のデフォルト倉庫の取得が走る
  setup do
    InventoryStub.stub_defaults()
    :ok
  end

  @orders "/api/v1/shipment_orders"
  @lot "01JE0000000000000000000001"
  @order_id "01JD0000000000000000000001"

  defp allocate_route(fun), do: {"POST", @orders, fun}
  defp list_route(fun), do: {"GET", @orders, fun}
  defp cancel_route(fun), do: {"POST", ~r{/cancel$}, fun}

  # 受け取った引当要求の数量どおりに引き当てる応答
  defp allocating(conn_fun \\ & &1) do
    fn conn ->
      %{"lines" => [line], "external_slip_id" => slip_id} = conn.assigns.body
      conn = conn_fun.(conn)

      InventoryStub.json(
        conn,
        201,
        InventoryStub.order(%{
          order_id: @order_id,
          external_slip_id: slip_id,
          req_pieces: line["req_pieces"],
          allocations: [{@lot, "2026-12-20", line["req_pieces"]}]
        })
      )
    end
  end

  defp new_slip_params(client, item, extra \\ %{}) do
    Map.merge(
      %{
        client_id: client.id,
        shipping_item_id: item.id,
        scheduled_ship_date: "2026-11-20",
        order_count: "3"
      },
      extra
    )
  end

  # ブラウザが送る `_target`(変更された入力)つきで change イベントを送る
  defp change_field(lv, field, params) do
    lv
    |> form("#shipping-slip-form", shipping_slip: params)
    |> render_change(%{_target: ["shipping_slip", to_string(field)]})
  end

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/shipping_slips/new")
    end

    test "viewer は入れない", %{conn: conn} do
      user = user_fixture(%{role: :viewer, must_change_password: false})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
               conn |> log_in_user(user) |> live(~p"/shipping_slips/new")

      slip = slip_fixture()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
               conn |> log_in_user(user) |> live(~p"/shipping_slips/#{slip.id}/edit")
    end
  end

  describe "staff: 登録" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "発注元・商品の選択肢にアーカイブ済みを出さない", %{conn: conn} do
      admin = user_scope_fixture()
      client = client_fixture(%{client_name: "休止発注元"})
      item = shipping_item_fixture(%{item_name: "休止商品"})
      active_client = client_fixture(%{client_name: "有効発注元"})
      {:ok, _} = FoodShip.Clients.archive_client(admin, client)
      {:ok, _} = FoodShip.ShippingItems.archive_shipping_item(admin, item)

      {:ok, _lv, html} = live(conn, ~p"/shipping_slips/new")

      assert html =~ active_client.client_name
      refute html =~ "休止発注元"
      refute html =~ "休止商品"
    end

    test "入力すると、出庫総数量・箱数・最低許容期限日がリアルタイムに表示される", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})

      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 30
      })

      {:ok, lv, html} = live(conn, ~p"/shipping_slips/new")
      assert html =~ "制限なし"

      html =
        lv
        |> form("#shipping-slip-form", shipping_slip: new_slip_params(client, item))
        |> render_change()

      assert html =~ "36 個"
      assert html =~ "2026-12-20"
      assert has_element?(lv, "#preview-total-piece-qty", "36 個")

      assert has_element?(
               lv,
               "#shipping-slip-form input[name='shipping_slip[box_count]'][value='6']"
             )

      # バラ数は入力欄ではない(手修正できない)
      refute has_element?(lv, "input[name='shipping_slip[total_piece_qty]']")
    end

    test "箱数を手修正すると、件数を変えても上書きしない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture(%{boxes_per_order: 2, pieces_per_order: 12})
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form", shipping_slip: new_slip_params(client, item))
      |> render_change()

      change_field(lv, :box_count, %{box_count: "9"})
      change_field(lv, :order_count, %{order_count: "5"})

      assert has_element?(
               lv,
               "#shipping-slip-form input[name='shipping_slip[box_count]'][value='9']"
             )

      assert has_element?(lv, "#preview-total-piece-qty", "60 個")
    end

    test "登録すると pending で保存され、在庫 API の引当が成功すれば引当済みになる", %{conn: conn, user: user} do
      client = client_fixture()
      item = shipping_item_fixture()
      InventoryStub.routes([allocate_route(allocating())])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form",
        shipping_slip: new_slip_params(client, item, %{client_slip_no: "PO-100"})
      )
      |> render_submit()

      {path, flash} = assert_redirect(lv, 2000)
      assert path == "/shipping_slips?date=2026-11-20"
      assert flash["info"] == "引き当てました。"

      assert [slip] = Repo.all(ShippingSlip) |> Repo.preload(:allocated_lots)
      assert slip.status == :allocated
      assert slip.client_slip_no == "PO-100"
      assert slip.created_by_user_id == user.id
      assert slip.inventory_order_id == @order_id
      assert [%{allocated_pieces: 36}] = slip.allocated_lots

      assert [{"POST", @orders, %{"operator" => operator}}] = InventoryStub.calls()
      assert operator == user.email
    end

    test "在庫が不足していれば shortage で保存し、不足数を表示する", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()

      InventoryStub.routes([
        allocate_route(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 7}]
          })
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form", shipping_slip: new_slip_params(client, item))
      |> render_submit()

      {_path, flash} = assert_redirect(lv, 2000)
      assert flash["error"] =~ "在庫が不足しています(不足 7 個)"

      assert [%{status: :shortage, shortage_pieces: 7}] = Repo.all(ShippingSlip)
    end

    test "通信に失敗しても、入力内容は pending で保存され、再引当を促す", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()
      InventoryStub.routes([allocate_route(&InventoryStub.timeout/1)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form",
        shipping_slip: new_slip_params(client, item, %{client_slip_no: "PO-7"})
      )
      |> render_submit()

      {_path, flash} = assert_redirect(lv, 2000)
      assert flash["error"] =~ "通信に失敗しました。再引当を押してください。"

      assert [slip] = Repo.all(ShippingSlip)
      assert slip.status == :pending
      assert slip.allocation_error == :connection
      assert slip.client_slip_no == "PO-7"
      assert slip.order_count == 3
    end

    test "恒久エラーは、設定またはマスタの確認を促す", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()

      InventoryStub.routes([
        allocate_route(fn conn -> InventoryStub.error(conn, 404, "not_found") end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form", shipping_slip: new_slip_params(client, item))
      |> render_submit()

      {_path, flash} = assert_redirect(lv, 2000)
      assert flash["error"] =~ "再試行しても直りません。設定またはマスタを確認してください"
      assert [%{allocation_error: :not_found}] = Repo.all(ShippingSlip)
    end

    test "引当の実行中は入力を無効にし、二重に送れない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()
      test_pid = self()

      # 在庫 API の応答を、テストが許可するまで待たせる
      InventoryStub.routes([
        allocate_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          allocating().(conn)
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      lv
      |> form("#shipping-slip-form", shipping_slip: new_slip_params(client, item))
      |> render_submit()

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#allocating")
      assert has_element?(lv, "#shipping-slip-form fieldset[disabled]")

      # もう一度送っても、伝票は増えない
      render_submit(lv, "save", %{
        "shipping_slip" =>
          Map.new(new_slip_params(client, item), fn {k, v} -> {to_string(k), v} end)
      })

      send(api_pid, :continue)

      assert_redirect(lv, 2000)
      assert Repo.aggregate(ShippingSlip, :count) == 1
    end

    test "二重登録は「すでに登録されています。」で拒否し、在庫 API を呼ばない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()
      slip_fixture(%{client_id: client.id, shipping_item_id: item.id, client_slip_no: "PO-1"})
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      html =
        lv
        |> form("#shipping-slip-form",
          shipping_slip: new_slip_params(client, item, %{client_slip_no: "PO-1"})
        )
        |> render_submit()

      assert html =~ "はすでに登録されています。"
      assert Repo.aggregate(ShippingSlip, :count) == 1
      assert InventoryStub.calls() == []
    end

    test "件数が不正ならエラーを表示して保存しない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/new")

      html =
        lv
        |> form("#shipping-slip-form",
          shipping_slip: new_slip_params(client, item, %{order_count: "0"})
        )
        |> render_submit()

      assert html =~ "must be greater than 0"
      assert Repo.aggregate(ShippingSlip, :count) == 0
    end

    test "デフォルト倉庫が未設定なら警告を出し、保存しない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()

      InventoryStub.routes([
        {"GET", "/api/v1/warehouses", &InventoryStub.without_default_warehouse/1}
      ])

      {:ok, lv, html} = live(conn, ~p"/shipping_slips/new")
      assert html =~ "対象倉庫が設定されていません。管理者に連絡してください。"
      assert has_element?(lv, "#warehouse-warning")

      html =
        render_submit(lv, "save", %{
          "shipping_slip" =>
            Map.new(new_slip_params(client, item), fn {k, v} -> {to_string(k), v} end)
        })

      assert html =~ "対象倉庫が設定されていません。"
      assert Repo.aggregate(ShippingSlip, :count) == 0
    end
  end

  describe "staff: 変更" do
    @describetag role: :staff
    setup :register_and_log_in_user

    defp allocated_slip(scope, attrs \\ %{}) do
      slip = slip_fixture(attrs, scope)
      InventoryStub.routes([allocate_route(allocating())])
      {:ok, slip, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
      InventoryStub.calls()
      slip
    end

    test "伝票の概要と、確認ダイアログの注意(在庫不足なら引当が解除される)を表示する", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope, %{client_slip_no: "PO-5"})
      {:ok, lv, html} = live(conn, ~p"/shipping_slips/#{slip.id}/edit")

      assert html =~ ShippingSlip.slip_no_label(slip)
      assert html =~ "PO-5"
      refute has_element?(lv, "select")
      assert html =~ "在庫不足の場合、現在の引当は解除されます"
    end

    test "件数を変えると箱数・出庫総数量が再計算され、保存すると旧オーダーを解除して再引当する", %{conn: conn, scope: scope, user: user} do
      slip = allocated_slip(scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/#{slip.id}/edit")

      html = change_field(lv, :order_count, %{order_count: "5"})

      assert html =~ "60 個"

      assert has_element?(
               lv,
               "#shipping-slip-form input[name='shipping_slip[box_count]'][value='10']"
             )

      old = InventoryStub.order(%{external_slip_id: slip.id, order_id: @order_id})
      new_id = "01JD0000000000000000000002"

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => [old]}) end),
        cancel_route(fn conn ->
          InventoryStub.json(conn, 200, Map.put(old, "status", "cancelled"))
        end),
        allocate_route(fn conn ->
          InventoryStub.json(
            conn,
            201,
            InventoryStub.order(%{
              order_id: new_id,
              external_slip_id: slip.id,
              req_pieces: 60,
              allocations: [{@lot, "2026-12-20", 60}]
            })
          )
        end)
      ])

      lv
      |> form("#shipping-slip-form",
        shipping_slip: %{order_count: "5", scheduled_ship_date: "2026-11-25"}
      )
      |> render_submit()

      {path, flash} = assert_redirect(lv, 2000)
      assert path == "/shipping_slips?date=2026-11-25"
      assert flash["info"] == "引き当てました。"

      changed = ShippingSlips.get_shipping_slip!(slip.id)
      assert changed.status == :allocated
      assert changed.order_count == 5
      assert changed.total_piece_qty == 60
      assert changed.box_count == 10
      assert changed.scheduled_ship_date == ~D[2026-11-25]
      assert changed.inventory_order_id == new_id

      assert [
               {"GET", _, _},
               {"POST", cancel_path, %{"operator" => operator}},
               {"POST", @orders, _}
             ] =
               InventoryStub.calls()

      assert String.ends_with?(cancel_path, "/cancel")
      assert operator == user.email
    end

    test "再引当が在庫不足になると、旧引当は解除されたまま shortage になる", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/#{slip.id}/edit")
      old = InventoryStub.order(%{external_slip_id: slip.id, order_id: @order_id})

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => [old]}) end),
        cancel_route(fn conn ->
          InventoryStub.json(conn, 200, Map.put(old, "status", "cancelled"))
        end),
        allocate_route(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 24}]
          })
        end)
      ])

      lv |> form("#shipping-slip-form", shipping_slip: %{order_count: "9"}) |> render_submit()

      {_path, flash} = assert_redirect(lv, 2000)
      assert flash["error"] =~ "不足 24 個"

      changed = ShippingSlips.get_shipping_slip!(slip.id)
      assert changed.status == :shortage
      assert changed.inventory_order_id == nil
      assert changed.allocated_lots == []
    end

    test "登録済みの箱数は、件数を変えない限り守られる", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{box_count: 7}, scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/#{slip.id}/edit")

      lv
      |> form("#shipping-slip-form", shipping_slip: %{scheduled_ship_date: "2026-11-22"})
      |> render_change()

      assert has_element?(
               lv,
               "#shipping-slip-form input[name='shipping_slip[box_count]'][value='7']"
             )

      change_field(lv, :order_count, %{order_count: "4"})

      assert has_element?(
               lv,
               "#shipping-slip-form input[name='shipping_slip[box_count]'][value='8']"
             )
    end

    test "梱包済み・取消済みの伝票は変更画面に入れない", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{}, scope)

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
        set: [
          status: :cancelled,
          cancelled_at: DateTime.utc_now(:second),
          cancelled_by_user_id: scope.user.id
        ]
      )

      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => "この伝票は変更できません。"}}}} =
               live(conn, ~p"/shipping_slips/#{slip.id}/edit")

      assert path == "/shipping_slips?date=2026-11-20"
    end
  end
end
