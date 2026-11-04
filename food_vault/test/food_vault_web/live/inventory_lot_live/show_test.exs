defmodule FoodVaultWeb.InventoryLotLive.ShowTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.InventoriesFixtures
  import Phoenix.LiveViewTest

  test "未ログインはログイン画面へ", %{conn: conn} do
    lot = lot_fixture()

    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/inventory_lots/#{lot.id}")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "ロットの数量と受払履歴を表示する", %{conn: conn} do
      lot = lot_fixture(%{case_qty: 3, piece_qty: 2})
      {:ok, lv, html} = live(conn, ~p"/inventory_lots/#{lot.id}")

      assert html =~ "3 | 2 | 38"
      assert has_element?(lv, "#lot-transactions", "入荷")
    end
  end

  describe "引当しているオーダー" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "そのロットを引き当てているオーダーを表示し、取消済みは出さない", %{conn: conn} do
      order = FoodVault.ShipmentOrdersFixtures.order_fixture()
      lot_id = hd(hd(order.lines).allocations).lot_id
      {:ok, lv, _} = live(conn, ~p"/inventory_lots/#{lot_id}")

      assert has_element?(lv, "#allocating-#{order.id}", "画面登録")

      staff = FoodVault.AccountsFixtures.user_fixture(%{role: :staff})
      {:ok, _} = FoodVault.ShipmentOrders.cancel_shipment_order(staff, order)
      {:ok, lv, _} = live(conn, ~p"/inventory_lots/#{lot_id}")

      refute has_element?(lv, "#allocating-#{order.id}")
      assert has_element?(lv, "td", "引当中のオーダーはありません。")
    end

    test "棚卸調整のリンクは admin だけに出る", %{conn: conn} do
      lot = lot_fixture()
      {:ok, lv, _} = live(conn, ~p"/inventory_lots/#{lot.id}")
      refute has_element?(lv, "#new-adjustment")

      admin = FoodVault.AccountsFixtures.admin_fixture()
      {:ok, lv, _} = conn |> log_in_user(admin) |> live(~p"/inventory_lots/#{lot.id}")
      assert has_element?(lv, "#new-adjustment")
    end
  end
end
