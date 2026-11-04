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
end
