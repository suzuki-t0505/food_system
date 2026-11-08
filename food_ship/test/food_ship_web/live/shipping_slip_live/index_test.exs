defmodule FoodShipWeb.ShippingSlipLive.IndexTest do
  # Task から Req.Test・DB を使うため async: false(共有モード)
  use FoodShipWeb.ConnCase, async: false

  import Ecto.Query
  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.ShippingSlipsFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.{InventoryStub, Repo, ShippingSlips}
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.Utils.ConvertDatetime

  setup {Req.Test, :set_req_test_from_context}

  # 画面の表示・伝票の作成では、在庫のデフォルト倉庫の取得が走る
  setup do
    InventoryStub.stub_defaults()
    :ok
  end

  @orders "/api/v1/shipment_orders"
  @date ~D[2026-11-20]
  @date_param "2026-11-20"
  @lot1 "01JE0000000000000000000001"
  @lot2 "01JE0000000000000000000002"
  @order_id "01JD0000000000000000000001"

  defp allocate_route(fun), do: {"POST", @orders, fun}
  defp list_route(fun), do: {"GET", @orders, fun}
  defp cancel_route(fun), do: {"POST", ~r{/cancel$}, fun}
  defp ship_route(fun), do: {"POST", ~r{/ship$}, fun}
  defp get_route(fun), do: {"GET", ~r{/shipment_orders/[^/]+$}, fun}

  defp order_for(slip, attrs \\ %{}) do
    Map.merge(
      %{
        order_id: @order_id,
        external_slip_id: slip.id,
        req_pieces: slip.total_piece_qty,
        allocations: [{@lot1, "2026-12-20", 20}, {@lot2, "2026-12-25", slip.total_piece_qty - 20}]
      },
      attrs
    )
    |> InventoryStub.order()
  end

  defp allocated_slip(scope, attrs \\ %{}) do
    slip = slip_fixture(Map.put_new(attrs, :scheduled_ship_date, @date), scope)

    InventoryStub.routes([
      allocate_route(fn conn -> InventoryStub.json(conn, 201, order_for(slip)) end)
    ])

    {:ok, slip, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    InventoryStub.calls()
    slip
  end

  defp shortage_slip(scope, attrs \\ %{}) do
    slip = slip_fixture(Map.put_new(attrs, :scheduled_ship_date, @date), scope)

    InventoryStub.routes([
      allocate_route(fn conn ->
        InventoryStub.error(conn, 422, "insufficient_stock", %{
          "shortages" => [%{"item_id" => "x", "shortage_pieces" => 7}]
        })
      end)
    ])

    {:ok, slip, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    InventoryStub.calls()
    slip
  end

  defp pending_slip(scope, error_stub, attrs \\ %{}) do
    slip = slip_fixture(Map.put_new(attrs, :scheduled_ship_date, @date), scope)
    InventoryStub.routes([allocate_route(error_stub)])
    {:ok, slip, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    InventoryStub.calls()
    slip
  end

  defp mark_packed(scope, slip) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
      set: [
        status: :packed,
        inventory_order_id: @order_id,
        packed_at: DateTime.utc_now(:second),
        packed_by_user_id: scope.user.id
      ]
    )
  end

  defp row(slip), do: "#slip-#{slip.id}"
  defp status_of(slip), do: Repo.get!(ShippingSlip, slip.id).status

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/shipping_slips")
  end

  describe "viewer(参照のみ)" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "伝票を見られるが、操作ボタン・登録リンクは出ない", %{conn: conn} do
      staff = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      shortage = shortage_slip(staff)
      allocated = allocated_slip(staff)

      {:ok, lv, html} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert html =~ ShippingSlip.slip_no_label(shortage)
      assert html =~ ShippingSlip.slip_no_label(allocated)
      refute has_element?(lv, "#new-shipping-slip")
      refute has_element?(lv, "#reallocate-#{shortage.id}")
      refute has_element?(lv, "#cancel-#{allocated.id}")
      refute has_element?(lv, "#edit-#{allocated.id}")
      refute has_element?(lv, "#warehouse-warning")
    end

    test "イベントを直接送っても、再引当・取消はできず、在庫 API も呼ばない", %{conn: conn} do
      staff = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      shortage = shortage_slip(staff)
      allocated = allocated_slip(staff)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert render_click(lv, "reallocate", %{"id" => shortage.id}) =~ "権限がありません。"
      assert render_click(lv, "cancel", %{"id" => allocated.id}) =~ "権限がありません。"

      assert status_of(shortage) == :shortage
      assert status_of(allocated) == :allocated
      assert InventoryStub.calls() == []
    end
  end

  describe "表示" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "引当ロットの「期限日 × 個数」と、期限なしを表示する", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      no_expiry = slip_fixture(%{scheduled_ship_date: @date}, scope)

      InventoryStub.routes([
        allocate_route(fn conn ->
          InventoryStub.json(
            conn,
            201,
            order_for(no_expiry, %{
              order_id: "01JD0000000000000000000002",
              allocations: [{@lot1, "9999-12-31", 36}]
            })
          )
        end)
      ])

      {:ok, _, _} = ShippingSlips.allocate_shipping_slip(scope, no_expiry)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, row(slip), "2026-12-20 × 20 個")
      assert has_element?(lv, row(slip), "2026-12-25 × 16 個")
      assert has_element?(lv, row(no_expiry), "期限なし × 36 個")
    end

    test "発注元・商品・件数・箱数・バラ数・状態を表示する", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "表示発注元"})
      item = shipping_item_fixture(%{item_name: "表示商品", boxes_per_order: 2, pieces_per_order: 12})

      slip =
        shortage_slip(scope, %{
          client_id: client.id,
          shipping_item_id: item.id,
          client_slip_no: "PO-77"
        })

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, row(slip), "表示発注元")
      assert has_element?(lv, row(slip), "表示商品")
      assert has_element?(lv, row(slip), "PO-77")
      assert has_element?(lv, row(slip), "在庫不足")
      assert has_element?(lv, row(slip), "不足 7 個")
    end

    test "pending の行は、一時エラーなら再引当を促し、最終試行日時(JST)を表示する", %{conn: conn, scope: scope} do
      slip = pending_slip(scope, &InventoryStub.timeout/1)
      attempted = Repo.get!(ShippingSlip, slip.id).allocation_attempted_at

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, "#pending-#{slip.id}", "通信に失敗しました。再引当を押してください。")

      assert has_element?(
               lv,
               "#pending-#{slip.id}",
               "最終試行: #{ConvertDatetime.format_jst(attempted)}"
             )
    end

    test "pending の行は、恒久エラーなら設定・マスタの確認を促し、原因を表示する", %{conn: conn, scope: scope} do
      slip = pending_slip(scope, fn conn -> InventoryStub.error(conn, 404, "not_found") end)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, "#pending-#{slip.id}", "再試行しても直りません。設定またはマスタを確認してください")
      assert has_element?(lv, "#pending-#{slip.id}", "在庫システムに商品が見つかりません")
    end

    test "出荷予定日のタブに残件数を表示し、未指定なら今日以降で最も近い日付を開く", %{conn: conn, scope: scope} do
      today = ConvertDatetime.today_jst()
      near = Date.add(today, 2)
      far = Date.add(today, 5)
      allocated_slip(scope, %{scheduled_ship_date: near})
      shortage_slip(scope, %{scheduled_ship_date: near})
      packed = slip_fixture(%{scheduled_ship_date: far}, scope)
      mark_packed(scope, packed)
      slip_fixture(%{scheduled_ship_date: far}, scope)

      {:ok, lv, html} = live(conn, ~p"/shipping_slips")

      assert has_element?(lv, "#tab-#{near}", "#{Calendar.strftime(near, "%m/%d")} (残2件)")
      assert has_element?(lv, "#tab-#{far}", "(残1件)")
      assert has_element?(lv, "#tab-#{near}.tab-active")
      assert html =~ "S-"
    end

    test "範囲外の日付を指定しても、その日のタブと伝票を表示できる", %{conn: conn, scope: scope} do
      old = Date.add(ConvertDatetime.today_jst(), -30)
      slip = slip_fixture(%{scheduled_ship_date: old}, scope)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{Date.to_iso8601(old)}")

      assert has_element?(lv, "#tab-#{old}", "(残1件)")
      assert has_element?(lv, row(slip))
    end

    test "日付が不正なら今日を表示する(例外にしない)", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=bad&filter=unknown")

      assert has_element?(lv, "#no-slips")
      assert has_element?(lv, "#filter-all.btn-active")
    end

    test "状態フィルタ(すべて／未梱包のみ／在庫不足のみ)で絞れる", %{conn: conn, scope: scope} do
      pending = slip_fixture(%{scheduled_ship_date: @date}, scope)
      allocated = allocated_slip(scope)
      shortage = shortage_slip(scope)
      packed = slip_fixture(%{scheduled_ship_date: @date}, scope)
      mark_packed(scope, packed)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      for slip <- [pending, allocated, shortage, packed], do: assert(has_element?(lv, row(slip)))

      lv |> element("#filter-unpacked") |> render_click()
      assert_patch(lv)
      for slip <- [pending, allocated, shortage], do: assert(has_element?(lv, row(slip)))
      refute has_element?(lv, row(packed))

      lv |> element("#filter-shortage") |> render_click()
      assert_patch(lv)
      assert has_element?(lv, row(shortage))
      refute has_element?(lv, row(pending))
      refute has_element?(lv, row(allocated))

      lv |> element("#filter-all") |> render_click()
      assert_patch(lv)
      assert has_element?(lv, row(packed))
    end

    test "梱包完了の伝票があるタブでは、未梱包の追加伝票をハイライトし、梱包済みをグレーアウトする", %{conn: conn, scope: scope} do
      packed = slip_fixture(%{scheduled_ship_date: @date}, scope)
      mark_packed(scope, packed)
      added = slip_fixture(%{scheduled_ship_date: @date}, scope)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, "#{row(added)}.bg-warning\\/20")
      assert has_element?(lv, row(added), "追加")
      assert has_element?(lv, "#{row(packed)}.opacity-50")
      refute has_element?(lv, row(packed), "追加")
    end

    test "梱包完了の伝票が無ければハイライトしない", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{scheduled_ship_date: @date}, scope)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      refute has_element?(lv, "#{row(slip)}.bg-warning\\/20")
    end

    test "デフォルト倉庫が未設定なら警告を出す", %{conn: conn} do
      InventoryStub.routes([
        {"GET", "/api/v1/warehouses", &InventoryStub.without_default_warehouse/1}
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, "#warehouse-warning", "対象倉庫が設定されていません。")
    end

    test "在庫 API に接続できないときは、未設定の警告を出さない", %{conn: conn} do
      InventoryStub.routes([{"GET", "/api/v1/warehouses", &InventoryStub.timeout/1}])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      refute has_element?(lv, "#warehouse-warning")
    end

    test "日付の入力で、その日のタブへ移動する", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{scheduled_ship_date: ~D[2026-12-01]}, scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      lv |> form("#select-date-form", %{date: "2026-12-01"}) |> render_change()

      assert_patch(lv, ~p"/shipping_slips?#{%{date: "2026-12-01", filter: :all}}")
      assert has_element?(lv, row(slip))
    end

    test "数量変更のリンクは変更画面へ", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      assert has_element?(lv, ~s(a#edit-#{slip.id}[href="/shipping_slips/#{slip.id}/edit"]))
    end
  end

  describe "再引当" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "在庫不足の伝票を再引当すると、引当済みになる(処理中は行のボタンを無効にする)", %{conn: conn, scope: scope, user: user} do
      slip = shortage_slip(scope)
      test_pid = self()

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end),
        allocate_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          InventoryStub.json(conn, 201, order_for(slip))
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-#{slip.id}") |> render_click()

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#reallocate-#{slip.id}[disabled]")
      assert has_element?(lv, "#cancel-#{slip.id}[disabled]")
      assert has_element?(lv, row(slip), "処理中")

      # 処理中にもう一度押しても、在庫 API は 1 回しか呼ばれない
      render_click(lv, "reallocate", %{"id" => slip.id})
      send(api_pid, :continue)

      wait_until(fn -> assert render(lv) =~ "引き当てました。" end)

      assert status_of(slip) == :allocated
      assert has_element?(lv, row(slip), "2026-12-20 × 20 個")
      refute has_element?(lv, "#reallocate-#{slip.id}")
      assert has_element?(lv, "#tab-#{@date}", "(残1件)")

      calls = InventoryStub.calls()
      assert Enum.count(calls, &match?({"POST", @orders, _}, &1)) == 1
      assert {"POST", @orders, %{"operator" => operator}} = List.last(calls)
      assert operator == user.email
    end

    test "通信失敗で pending の伝票は、再引当で復旧できる", %{conn: conn, scope: scope} do
      slip = pending_slip(scope, &InventoryStub.timeout/1)

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end),
        allocate_route(fn conn -> InventoryStub.json(conn, 201, order_for(slip)) end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      assert has_element?(lv, "#pending-#{slip.id}")

      lv |> element("#reallocate-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "引き当てました。" end)
      assert status_of(slip) == :allocated
      refute has_element?(lv, "#pending-#{slip.id}")
    end

    test "再引当でも在庫不足なら、不足数を表示する", %{conn: conn, scope: scope} do
      slip = shortage_slip(scope)

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end),
        allocate_route(fn conn ->
          InventoryStub.error(conn, 422, "insufficient_stock", %{
            "shortages" => [%{"item_id" => "x", "shortage_pieces" => 3}]
          })
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "不足 3 個" end)
      assert status_of(slip) == :shortage
    end

    test "再引当にも失敗したら、エラーを表示して pending のまま残る", %{conn: conn, scope: scope} do
      slip = shortage_slip(scope)

      InventoryStub.routes([
        list_route(&InventoryStub.timeout/1)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "通信に失敗しました。再引当を押してください。" end)
      assert status_of(slip) == :pending
      assert has_element?(lv, "#reallocate-#{slip.id}")
    end
  end

  describe "梱包完了" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "引当済みの行にだけ「梱包完了」が出る。梱包完了すると packed になり、行がグレーアウトする", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      slip = allocated_slip(scope)
      shortage = shortage_slip(scope)
      shipped = order_for(slip, %{status: "shipped", shipped_at: "2026-11-20T01:02:03Z"})
      InventoryStub.routes([ship_route(fn conn -> InventoryStub.json(conn, 200, shipped) end)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      assert has_element?(lv, "#pack-#{slip.id}")
      refute has_element?(lv, "#pack-#{shortage.id}")

      lv |> element("#pack-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "梱包完了にしました。" end)

      packed = Repo.get!(ShippingSlip, slip.id)
      assert packed.status == :packed
      assert packed.packed_by_user_id == user.id
      assert packed.packed_at == ~U[2026-11-20 01:02:03Z]

      assert has_element?(lv, "#{row(slip)}.opacity-50")
      refute has_element?(lv, "#pack-#{slip.id}")
      refute has_element?(lv, "#cancel-#{slip.id}")
      refute has_element?(lv, "#box-form-#{slip.id}")
      assert has_element?(lv, row(slip), "梱包完了")
      assert has_element?(lv, "#tab-#{@date}", "(残1件)")

      assert [{"POST", ship_path, %{"operator" => operator}}] = InventoryStub.calls()
      assert ship_path == "#{@orders}/#{@order_id}/ship"
      assert operator == user.email
    end

    test "処理中は行のボタンを無効にし、二重に押しても在庫 API は 1 回だけ", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      test_pid = self()

      InventoryStub.routes([
        ship_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          InventoryStub.json(
            conn,
            200,
            order_for(slip, %{status: "shipped", shipped_at: "2026-11-20T01:02:03Z"})
          )
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#pack-#{slip.id}") |> render_click()

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#pack-#{slip.id}[disabled]")
      assert has_element?(lv, "#update-box-count-#{slip.id}[disabled]")

      render_click(lv, "pack", %{"id" => slip.id})
      send(api_pid, :continue)

      wait_until(fn -> assert render(lv) =~ "梱包完了にしました。" end)
      assert Enum.count(InventoryStub.calls(), &match?({"POST", _, _}, &1)) == 1
    end

    test "在庫システムが停止している間は失敗して引当済みのまま。復旧後にやり直せる", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      InventoryStub.routes([ship_route(&InventoryStub.timeout/1)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#pack-#{slip.id}") |> render_click()

      wait_until(fn ->
        assert render(lv) =~ "時間をおいて、もう一度梱包完了を行ってください。"
      end)

      assert status_of(slip) == :allocated
      assert has_element?(lv, "#pack-#{slip.id}:not([disabled])")

      InventoryStub.routes([
        ship_route(fn conn ->
          InventoryStub.json(
            conn,
            200,
            order_for(slip, %{status: "shipped", shipped_at: "2026-11-20T01:02:03Z"})
          )
        end)
      ])

      lv |> element("#pack-#{slip.id}") |> render_click()
      wait_until(fn -> assert render(lv) =~ "梱包完了にしました。" end)
      assert status_of(slip) == :packed
      # 前の失敗のメッセージは残らない(最新の結果だけを表示する)
      refute render(lv) =~ "時間をおいて、もう一度梱包完了を行ってください。"
    end

    test "409 が返り、在庫側がすでに出庫済みなら、梱包完了に更新する", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      shipped = order_for(slip, %{status: "shipped", shipped_at: "2026-11-20T05:00:00Z"})

      InventoryStub.routes([
        ship_route(fn conn -> InventoryStub.error(conn, 409, "invalid_state") end),
        get_route(fn conn -> InventoryStub.json(conn, 200, shipped) end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#pack-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "梱包完了にしました。" end)
      assert status_of(slip) == :packed
    end

    test "409 で在庫側が出庫済みでなければ、最新の状態を表示してエラーにする", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      cancelled = order_for(slip, %{status: "cancelled"})

      InventoryStub.routes([
        ship_route(fn conn -> InventoryStub.error(conn, 409, "invalid_state") end),
        get_route(fn conn -> InventoryStub.json(conn, 200, cancelled) end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#pack-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫システムのオーダーの状態(cancelled)では、この操作はできません。" end)
      assert status_of(slip) == :allocated
    end
  end

  describe "箱数の修正" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "梱包前の伝票の箱数を修正できる(在庫 API は呼ばない)", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      lv |> form("#box-form-#{slip.id}", %{box_count: "4"}) |> render_submit()

      assert Repo.get!(ShippingSlip, slip.id).box_count == 4
      assert has_element?(lv, "#box-form-#{slip.id} input[name='box_count'][value='4']")
      assert render(lv) =~ "箱数を更新しました。"
      assert InventoryStub.calls() == []
    end

    test "1 未満の箱数はエラーで、変わらない", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      for value <- ["0", "-2"] do
        html = lv |> form("#box-form-#{slip.id}", %{box_count: value}) |> render_submit()
        assert html =~ "箱数は 1 以上の整数で入力してください。"
      end

      assert Repo.get!(ShippingSlip, slip.id).box_count == slip.box_count
    end

    test "梱包済みの行には入力欄がなく、イベントを直接送っても修正できない", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{scheduled_ship_date: @date}, scope)
      mark_packed(scope, slip)
      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      refute has_element?(lv, "#box-form-#{slip.id}")

      html = render_submit(lv, "update_box_count", %{"slip_id" => slip.id, "box_count" => "9"})
      assert html =~ "現在の状態では、この操作はできません。"
      assert Repo.get!(ShippingSlip, slip.id).box_count == slip.box_count
    end
  end

  describe "viewer は梱包完了・箱数の修正ができない" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "ボタン・入力欄が出ず、イベントを直接送っても拒否され、在庫 API も呼ばない", %{conn: conn} do
      staff = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      slip = allocated_slip(staff)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      refute has_element?(lv, "#pack-#{slip.id}")
      refute has_element?(lv, "#box-form-#{slip.id}")

      assert render_click(lv, "pack", %{"id" => slip.id}) =~ "権限がありません。"

      assert render_submit(lv, "update_box_count", %{"slip_id" => slip.id, "box_count" => "9"}) =~
               "権限がありません。"

      row_in_db = Repo.get!(ShippingSlip, slip.id)
      assert row_in_db.status == :allocated
      assert row_in_db.box_count == slip.box_count
      assert InventoryStub.calls() == []
    end
  end

  describe "取消" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "引当済みの伝票を取り消すと、在庫側の引当を解除し、実行者と日時が記録される", %{conn: conn, scope: scope, user: user} do
      slip = allocated_slip(scope)
      order = order_for(slip)

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => [order]}) end),
        cancel_route(fn conn ->
          InventoryStub.json(conn, 200, Map.put(order, "status", "cancelled"))
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}&filter=unpacked")
      lv |> element("#cancel-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "伝票を取り消しました。" end)

      cancelled = Repo.get!(ShippingSlip, slip.id)
      assert cancelled.status == :cancelled
      assert cancelled.cancelled_by_user_id == user.id
      assert %DateTime{} = cancelled.cancelled_at
      refute has_element?(lv, row(slip))
      assert has_element?(lv, "#tab-#{@date}", "(残0件)")

      assert [{"GET", _, _}, {"POST", cancel_path, %{"operator" => operator}}] =
               InventoryStub.calls()

      assert cancel_path == "#{@orders}/#{@order_id}/cancel"
      assert operator == user.email
    end

    test "在庫 API を呼んでいない pending の伝票は、API を呼ばずに取り消せる", %{conn: conn, scope: scope} do
      slip = slip_fixture(%{scheduled_ship_date: @date}, scope)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#cancel-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "伝票を取り消しました。" end)
      assert status_of(slip) == :cancelled
      assert InventoryStub.calls() == []
    end

    test "在庫システムに接続できなければ、エラーを表示して伝票は変わらない(再度取消できる)", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      order = order_for(slip)

      InventoryStub.routes([
        list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => [order]}) end),
        cancel_route(&InventoryStub.timeout/1)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#cancel-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫システムに接続できませんでした。" end)

      row_in_db = Repo.get!(ShippingSlip, slip.id)
      assert row_in_db.status == :allocated
      assert row_in_db.cancelled_at == nil
      assert has_element?(lv, "#cancel-#{slip.id}:not([disabled])")
    end

    test "在庫側がすでに出庫済みなら取り消せず、梱包完了で状態を合わせるよう案内する", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      shipped = order_for(slip, %{status: "shipped", shipped_at: "2026-11-19T01:02:03Z"})

      InventoryStub.routes([
        list_route(fn conn ->
          InventoryStub.json(conn, 200, %{"shipment_orders" => [shipped]})
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#cancel-#{slip.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫システムではすでに出庫済みです。" end)
      assert status_of(slip) == :allocated
    end
  end
end
