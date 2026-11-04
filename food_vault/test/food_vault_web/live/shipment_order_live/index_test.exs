defmodule FoodVaultWeb.ShipmentOrderLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.MastersFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.ShipmentOrdersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.ShipmentOrders

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/shipment_orders")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、登録リンクは出ない", %{conn: conn} do
      order = order_fixture()
      {:ok, lv, html} = live(conn, ~p"/shipment_orders")

      assert has_element?(lv, "#order-#{order.id}", "引当済")
      assert html =~ "画面登録"
      refute has_element?(lv, "#new-shipment-order")
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "登録リンクが出る", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/shipment_orders")
      assert has_element?(lv, "#new-shipment-order")
    end

    test "状態と起源で絞り込める", %{conn: conn} do
      screen = order_fixture()
      lot = lot_fixture(%{case_qty: 2})

      {:ok, %{shipment_order: external}} =
        ShipmentOrders.allocate_shipment_order({:api, "ship@example.com"}, %{
          warehouse_id: lot.warehouse_id,
          shipment_date: ~D[2026-11-15],
          external_slip_id: "EXT-LIST",
          lines: [%{item_id: lot.item_id, req_cases: 1}]
        })

      {:ok, lv, _} = live(conn, ~p"/shipment_orders")
      assert has_element?(lv, "#order-#{screen.id}")
      assert has_element?(lv, "#order-#{external.id}", "EXT-LIST")

      lv |> form("#filter-form", filter: %{origin: "external"}) |> render_change()
      assert_patch(lv)
      assert has_element?(lv, "#order-#{external.id}")
      refute has_element?(lv, "#order-#{screen.id}")

      lv |> form("#filter-form", filter: %{origin: "", status: "shipped"}) |> render_change()
      assert_patch(lv)
      assert has_element?(lv, "td", "出庫オーダーがありません。")
    end

    test "倉庫で絞り込める", %{conn: conn} do
      order = order_fixture()
      other_warehouse = warehouse_fixture()

      {:ok, lv, _} = live(conn, ~p"/shipment_orders")
      lv |> form("#filter-form", filter: %{warehouse_id: other_warehouse.id}) |> render_change()
      assert_patch(lv)
      refute has_element?(lv, "#order-#{order.id}")
    end
  end
end
