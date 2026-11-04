defmodule FoodVaultWeb.ShipmentOrderLive.ShowTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.InventoriesFixtures
  import FoodVault.ShipmentOrdersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.{Repo, ShipmentOrders}
  alias FoodVault.Inventories.InventoryLot

  defp external_order! do
    lot = lot_fixture(%{case_qty: 2})

    {:ok, %{shipment_order: order}} =
      ShipmentOrders.allocate_shipment_order({:api, "ship@example.com"}, %{
        warehouse_id: lot.warehouse_id,
        shipment_date: ~D[2026-11-15],
        external_slip_id: "EXT-SHOW",
        lines: [%{item_id: lot.item_id, req_cases: 1}]
      })

    {order, lot}
  end

  test "未ログインはログイン画面へ", %{conn: conn} do
    order = order_fixture()

    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/shipment_orders/#{order.id}")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "引当ロットと履歴を見られるが、操作ボタンは出ない", %{conn: conn} do
      order = order_fixture()
      {:ok, lv, html} = live(conn, ~p"/shipment_orders/#{order.id}")

      assert html =~ "2027-01-01"
      assert has_element?(lv, "#order-events", "引当")
      refute has_element?(lv, "#ship-order")
      refute has_element?(lv, "#cancel-order")
    end

    test "イベントを直接送っても確定できない", %{conn: conn} do
      order = order_fixture()
      {:ok, lv, _} = live(conn, ~p"/shipment_orders/#{order.id}")

      assert render_click(lv, "ship", %{}) =~ "権限がありません。"
      assert ShipmentOrders.get_shipment_order!(order.id).status == :allocated
      assert render_click(lv, "cancel", %{}) =~ "権限がありません。"
      assert ShipmentOrders.get_shipment_order!(order.id).status == :allocated
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "出庫確定できる", %{conn: conn} do
      order = order_fixture()
      lot_id = hd(hd(order.lines).allocations).lot_id
      {:ok, lv, _} = live(conn, ~p"/shipment_orders/#{order.id}")

      html = lv |> element("#ship-order") |> render_click()

      assert html =~ "出庫を確定しました。"
      assert html =~ "出庫済"
      refute has_element?(lv, "#ship-order")
      assert ShipmentOrders.get_shipment_order!(order.id).status == :shipped
      assert Repo.get!(InventoryLot, lot_id).case_qty == 2
      assert has_element?(lv, "#order-events", "出庫確定")
    end

    test "引当解除できる", %{conn: conn} do
      order = order_fixture()
      lot_id = hd(hd(order.lines).allocations).lot_id
      {:ok, lv, _} = live(conn, ~p"/shipment_orders/#{order.id}")

      html = lv |> element("#cancel-order") |> render_click()

      assert html =~ "引当を解除しました。"
      assert ShipmentOrders.get_shipment_order!(order.id).status == :cancelled
      lot = Repo.get!(InventoryLot, lot_id)
      assert {lot.case_qty, lot.allocated_case_qty} == {3, 0}
    end

    test "別の画面で状態が変わっていたら、操作は拒否され最新の状態を表示する", %{conn: conn, user: user} do
      order = order_fixture()
      {:ok, lv, _} = live(conn, ~p"/shipment_orders/#{order.id}")

      {:ok, _} = ShipmentOrders.cancel_shipment_order(user, order)
      html = lv |> element("#ship-order") |> render_click()

      assert html =~ "このオーダーは現在の状態では操作できません。"
      refute has_element?(lv, "#ship-order")
    end

    test "発送システム起源のオーダーは警告を出し、操作できない", %{conn: conn} do
      {order, lot} = external_order!()
      {:ok, lv, html} = live(conn, ~p"/shipment_orders/#{order.id}")

      assert html =~ "EXT-SHOW"
      assert has_element?(lv, "#external-warning", "発送システムと状態がずれる")
      refute has_element?(lv, "#ship-order")
      refute has_element?(lv, "#cancel-order")

      assert render_click(lv, "ship", %{}) =~ "権限がありません。"
      assert render_click(lv, "cancel", %{}) =~ "権限がありません。"
      assert ShipmentOrders.get_shipment_order!(order.id).status == :allocated
      assert Repo.get!(InventoryLot, lot.id).allocated_case_qty == 1
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "admin でも発送システム起源のオーダーは画面から操作できない(緊急操作は P1)", %{conn: conn} do
      {order, _lot} = external_order!()
      {:ok, lv, _} = live(conn, ~p"/shipment_orders/#{order.id}")

      refute has_element?(lv, "#ship-order")
      assert render_click(lv, "cancel", %{}) =~ "権限がありません。"
    end
  end
end
