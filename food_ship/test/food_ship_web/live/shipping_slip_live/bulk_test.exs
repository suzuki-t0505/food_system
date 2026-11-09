defmodule FoodShipWeb.ShippingSlipLive.BulkTest do
  # 一括再引当・一括梱包完了(F-S5・F-S8)。Task から Req.Test・DB を使うため async: false(共有モード)
  use FoodShipWeb.ConnCase, async: false

  import Ecto.Query
  import FoodShip.AccountsFixtures
  import FoodShip.ShippingSlipsFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.{InventoryStub, Repo, ShippingSlips}
  alias FoodShip.ShippingSlips.ShippingSlip

  setup {Req.Test, :set_req_test_from_context}

  setup do
    InventoryStub.stub_defaults()
    :ok
  end

  @orders "/api/v1/shipment_orders"
  @date ~D[2026-11-20]
  @date_param "2026-11-20"
  @lot1 "01JE0000000000000000000001"
  @lot2 "01JE0000000000000000000002"

  defp order_for(slip, attrs \\ %{}) do
    Map.merge(
      %{
        order_id: Ecto.ULID.generate(),
        external_slip_id: slip.id,
        req_pieces: slip.total_piece_qty,
        allocations: [{@lot1, "2026-12-20", 20}, {@lot2, "2026-12-25", slip.total_piece_qty - 20}]
      },
      attrs
    )
    |> InventoryStub.order()
  end

  defp allocate_route(fun), do: {"POST", @orders, fun}
  defp list_route(fun), do: {"GET", @orders, fun}
  defp ship_route(fun), do: {"POST", ~r{/ship$}, fun}

  defp empty_list_route,
    do: list_route(fn conn -> InventoryStub.json(conn, 200, %{"shipment_orders" => []}) end)

  # 引当 API: 本文の external_slip_id の伝票に、引当成功を返す
  defp allocate_ok(conn) do
    slip = Repo.get!(ShippingSlip, conn.assigns.body["external_slip_id"])
    InventoryStub.json(conn, 201, order_for(slip))
  end

  defp pending_slip(scope, attrs \\ %{}) do
    slip_fixture(Map.put_new(attrs, :scheduled_ship_date, @date), scope)
  end

  defp set_row(slip, attrs) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id), set: attrs)
    slip
  end

  defp allocated_slip(scope, attrs \\ %{}) do
    slip = pending_slip(scope, attrs)
    order = order_for(slip)

    InventoryStub.routes([
      allocate_route(fn conn -> InventoryStub.json(conn, 201, order) end)
    ])

    {:ok, allocated, _} = ShippingSlips.allocate_shipping_slip(scope, slip)
    InventoryStub.calls()
    allocated
  end

  defp status_of(slip), do: Repo.get!(ShippingSlip, slip.id).status

  defp staff_scope,
    do: user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))

  defp allocate_calls, do: Enum.filter(InventoryStub.calls(), &match?({"POST", @orders, _}, &1))

  describe "viewer(参照のみ)" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一括のボタン・チェックボックスは出ず、イベントを直接送っても実行されない", %{conn: conn} do
      staff = staff_scope()
      pending = pending_slip(staff)
      allocated = allocated_slip(staff)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")

      refute has_element?(lv, "#reallocate-all")
      refute has_element?(lv, "#import-csv")
      refute has_element?(lv, "#pack-selected")
      refute has_element?(lv, "#select-#{allocated.id}")

      assert render_click(lv, "reallocate_all", %{}) =~ "権限がありません。"
      assert render_click(lv, "pack_selected", %{}) =~ "権限がありません。"
      render_click(lv, "toggle_select", %{"id" => allocated.id})

      assert status_of(pending) == :pending
      assert status_of(allocated) == :allocated
      assert InventoryStub.calls() == []
    end
  end

  describe "一括再引当" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "全日付の pending / shortage を、出荷予定日の昇順 → 伝票番号の昇順で引き当てる", %{
      conn: conn,
      scope: scope
    } do
      late = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-25]})
      early_a = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-21]})
      early_b = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-21]})
      shortage =
        set_row(pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-22]}), status: :shortage)

      # 恒久エラーの pending は対象外
      permanent = set_row(pending_slip(scope), allocation_error: :not_found)
      # 引当済みも対象外
      allocated = allocated_slip(scope)

      InventoryStub.routes([empty_list_route(), allocate_route(&allocate_ok/1)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()

      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert render(lv) =~ "4 件を処理しました(引当済み 4 件)。"

      posted =
        for {"POST", @orders, %{"external_slip_id" => id}} <- InventoryStub.calls(), do: id

      assert posted == [early_a.id, early_b.id, shortage.id, late.id]

      for slip <- [early_a, early_b, shortage, late], do: assert(status_of(slip) == :allocated)
      assert status_of(permanent) == :pending
      assert status_of(allocated) == :allocated

      # 伝票ごとの成否の一覧
      assert has_element?(lv, "#bulk-results", ShippingSlip.slip_no_label(late))
      assert has_element?(lv, "#bulk-results", "引当済み")
      refute has_element?(lv, "#bulk-results", ShippingSlip.slip_no_label(permanent))

      # 終了後は、一括のボタンが再び使える
      assert has_element?(lv, "#reallocate-all:not([disabled])")
    end

    test "伝票ごとの成否(引当済み・在庫不足・通信失敗)を一覧表示する", %{conn: conn, scope: scope} do
      ok = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-20]})
      short = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-21]})
      broken = pending_slip(scope, %{scheduled_ship_date: ~D[2026-11-22]})

      InventoryStub.routes([
        empty_list_route(),
        allocate_route(fn conn ->
          case conn.assigns.body["external_slip_id"] do
            id when id == short.id ->
              InventoryStub.error(conn, 422, "insufficient_stock", %{
                "shortages" => [%{"item_id" => "x", "shortage_pieces" => 7}]
              })

            id when id == broken.id ->
              InventoryStub.timeout(conn)

            _ ->
              allocate_ok(conn)
          end
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()

      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert render(lv) =~ "3 件を処理しました(引当済み 1 件・在庫不足 1 件・引当待ち 1 件)。"
      assert has_element?(lv, "#bulk-results", "在庫不足(不足 7 個)")
      assert has_element?(lv, "#bulk-results", "通信に失敗しました。再引当を押してください。")

      assert status_of(ok) == :allocated
      assert status_of(short) == :shortage
      assert status_of(broken) == :pending
    end

    test "実行中は一括ボタンと対象行が無効になり、二重に実行できない", %{conn: conn, scope: scope} do
      slip = pending_slip(scope)
      test_pid = self()

      InventoryStub.routes([
        empty_list_route(),
        allocate_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          allocate_ok(conn)
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#reallocate-all[disabled]")
      assert has_element?(lv, "#reallocate-#{slip.id}[disabled]")
      assert has_element?(lv, "#cancel-#{slip.id}[disabled]")
      assert has_element?(lv, "#bulk-progress", "0 / 1 件")
      refute has_element?(lv, "#close-bulk")

      # 実行中にもう一度送っても、何も起きない
      render_click(lv, "reallocate_all", %{})
      send(api_pid, :continue)

      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert has_element?(lv, "#bulk-progress", "1 / 1 件")
      assert length(allocate_calls()) == 1
      assert status_of(slip) == :allocated
    end

    test "対象が無ければ、その旨を表示する", %{conn: conn, scope: scope} do
      set_row(pending_slip(scope), allocation_error: :validation_failed)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()

      assert render(lv) =~ "再引当の対象がありません。"
      refute has_element?(lv, "#bulk-panel")
      assert InventoryStub.calls() == []
    end

    test "Task が途中で止まっても画面は元に戻り、残りは pending のまま残る", %{conn: conn, scope: scope} do
      slip = pending_slip(scope)

      InventoryStub.routes([
        empty_list_route(),
        allocate_route(fn _conn -> Process.exit(self(), :kill) end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()

      wait_until(fn -> assert render(lv) =~ "一括処理が中断しました" end)

      assert status_of(slip) == :pending
      assert has_element?(lv, "#reallocate-all:not([disabled])")
      assert has_element?(lv, "#reallocate-#{slip.id}:not([disabled])")
      assert has_element?(lv, "#close-bulk")
    end

    test "結果パネルは閉じられる", %{conn: conn, scope: scope} do
      pending_slip(scope)
      InventoryStub.routes([empty_list_route(), allocate_route(&allocate_ok/1)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#reallocate-all") |> render_click()
      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      lv |> element("#close-bulk") |> render_click()
      refute has_element?(lv, "#bulk-panel")
    end
  end

  describe "一括梱包完了" do
    @describetag role: :staff
    setup :register_and_log_in_user

    defp shipped_response(slip, order_id) do
      order_for(slip, %{
        order_id: order_id,
        status: "shipped",
        shipped_at: "2026-11-20T01:02:03Z"
      })
    end

    test "選択した伝票を 1 件ずつ梱包完了にし、進捗と成否を表示する", %{conn: conn, scope: scope, user: user} do
      a = allocated_slip(scope)
      b = allocated_slip(scope)
      untouched = allocated_slip(scope)

      InventoryStub.routes([
        ship_route(fn conn ->
          slip = Enum.find([a, b], &String.contains?(conn.request_path, &1.inventory_order_id))
          InventoryStub.json(conn, 200, shipped_response(slip, slip.inventory_order_id))
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      assert has_element?(lv, "#pack-selected[disabled]", "(0 件)")

      lv |> element("#select-#{a.id}") |> render_click()
      lv |> element("#select-#{b.id}") |> render_click()
      assert has_element?(lv, "#pack-selected:not([disabled])", "(2 件)")

      lv |> element("#pack-selected") |> render_click()
      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert render(lv) =~ "2 件を処理しました(梱包完了 2 件)。"
      assert has_element?(lv, "#bulk-progress", "2 / 2 件")
      assert has_element?(lv, "#bulk-results", ShippingSlip.slip_no_label(a))
      assert has_element?(lv, "#bulk-results", "梱包完了")

      for slip <- [a, b] do
        packed = Repo.get!(ShippingSlip, slip.id)
        assert packed.status == :packed
        assert packed.packed_by_user_id == user.id
      end

      assert status_of(untouched) == :allocated

      ship_paths = for {"POST", path, _} <- InventoryStub.calls(), do: path
      assert ship_paths == [
               "/api/v1/shipment_orders/#{a.inventory_order_id}/ship",
               "/api/v1/shipment_orders/#{b.inventory_order_id}/ship"
             ]
    end

    test "失敗した伝票は引当済みのまま残り、成否が一覧に出る", %{conn: conn, scope: scope} do
      ok = allocated_slip(scope)
      failing = allocated_slip(scope)

      InventoryStub.routes([
        ship_route(fn conn ->
          if String.contains?(conn.request_path, failing.inventory_order_id) do
            InventoryStub.timeout(conn)
          else
            InventoryStub.json(conn, 200, shipped_response(ok, ok.inventory_order_id))
          end
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#select-all") |> render_click()
      assert has_element?(lv, "#pack-selected", "(2 件)")

      lv |> element("#pack-selected") |> render_click()
      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert render(lv) =~ "2 件を処理しました(梱包完了 1 件・失敗 1 件)。"
      assert has_element?(lv, "#bulk-results", "在庫システムに接続できませんでした")

      assert status_of(ok) == :packed
      assert status_of(failing) == :allocated

      # 失敗した伝票は選択し直して、やり直せる
      assert has_element?(lv, "#select-#{failing.id}")
      assert has_element?(lv, "#pack-selected[disabled]", "(0 件)")
    end

    test "実行中は一括ボタン・チェックボックス・対象行が無効になり、二重に実行できない", %{conn: conn, scope: scope} do
      slip = allocated_slip(scope)
      other = allocated_slip(scope)
      test_pid = self()

      InventoryStub.routes([
        ship_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          InventoryStub.json(conn, 200, shipped_response(slip, slip.inventory_order_id))
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      lv |> element("#select-#{slip.id}") |> render_click()
      lv |> element("#pack-selected") |> render_click()

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#pack-selected[disabled]")
      assert has_element?(lv, "#reallocate-all[disabled]")
      assert has_element?(lv, "#select-all[disabled]")
      assert has_element?(lv, "#select-#{slip.id}[disabled]")
      assert has_element?(lv, "#pack-#{slip.id}[disabled]")
      assert has_element?(lv, "#bulk-progress", "0 / 1 件")

      # 実行中に別の伝票を選択・一括実行しようとしても、何も起きない
      render_click(lv, "toggle_select", %{"id" => other.id})
      render_click(lv, "pack_selected", %{})
      send(api_pid, :continue)

      wait_until(fn -> assert has_element?(lv, "#bulk-summary") end)

      assert status_of(slip) == :packed
      assert status_of(other) == :allocated
      assert has_element?(lv, "#pack-selected[disabled]", "(0 件)")
      assert Enum.count(InventoryStub.calls(), &match?({"POST", _, _}, &1)) == 1
    end

    test "全選択は、引当済みの行だけを選び、もう一度押すと解除する", %{conn: conn, scope: scope} do
      a = allocated_slip(scope)
      b = allocated_slip(scope)
      pending = pending_slip(scope)

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      refute has_element?(lv, "#select-#{pending.id}")

      lv |> element("#select-all") |> render_click()
      assert has_element?(lv, "#select-#{a.id}[checked]")
      assert has_element?(lv, "#select-#{b.id}[checked]")
      assert has_element?(lv, "#pack-selected", "(2 件)")

      lv |> element("#select-all") |> render_click()
      assert has_element?(lv, "#pack-selected[disabled]", "(0 件)")
    end

    test "引当済みでない伝票は選択できない", %{conn: conn, scope: scope} do
      pending = pending_slip(scope)
      InventoryStub.routes([])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips?date=#{@date_param}")
      render_click(lv, "toggle_select", %{"id" => pending.id})

      assert has_element?(lv, "#pack-selected[disabled]", "(0 件)")
      render_click(lv, "pack_selected", %{})
      assert render(lv) =~ "梱包完了にできる伝票が選択されていません。"
      assert InventoryStub.calls() == []
    end
  end
end
