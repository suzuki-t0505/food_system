defmodule FoodVaultWeb.InventoryTransactionLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import Phoenix.LiveViewTest

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/inventory_transactions")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "操作者付きの履歴を見られる", %{conn: conn} do
      staff = user_fixture(%{role: :staff, name: "入荷担当"})
      lot = lot_fixture(%{actor: staff, case_qty: 4})
      api_lot = lot_fixture(%{actor: {:api, "ship@example.com"}})

      {:ok, lv, html} = live(conn, ~p"/inventory_transactions")

      assert html =~ "入荷担当"
      assert html =~ "ship@example.com"
      assert has_element?(lv, "#transactions", "入荷")
      assert html =~ lot.id and html =~ api_lot.id
    end

    test "処理区分と操作ユーザーで絞り込める", %{conn: conn} do
      staff = user_fixture(%{role: :staff, name: "入荷担当"})
      lot = lot_fixture(%{actor: staff})
      other = lot_fixture(%{actor: {:api, "ship@example.com"}})

      {:ok, lv, _} = live(conn, ~p"/inventory_transactions")
      lv |> form("#filter-form", filter: %{user_id: staff.id}) |> render_change()
      assert_patch(lv)

      html = render(lv)
      assert html =~ lot.id
      refute html =~ other.id

      lv
      |> form("#filter-form", filter: %{user_id: "", transaction_type: "ship"})
      |> render_change()

      assert_patch(lv)
      assert has_element?(lv, "td", "履歴がありません。")
    end
  end
end
