defmodule FoodVaultWeb.Management.InventoryAdjustmentLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Inventories
  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.Repo

  test "未ログインはログイン画面へ", %{conn: conn} do
    lot = lot_fixture()

    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")
  end

  for role <- [:staff, :viewer] do
    test "#{role} は入れない", %{conn: conn} do
      lot = lot_fixture()
      user = user_fixture(%{role: unquote(role), must_change_password: false})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
               conn
               |> log_in_user(user)
               |> live(~p"/management/inventory_lots/#{lot.id}/adjustments/new")
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    setup do
      %{lot: lot_fixture(%{case_qty: 5, piece_qty: 4})}
    end

    test "調整後の数量がプレビューされる", %{conn: conn, lot: lot} do
      {:ok, lv, html} = live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")
      assert html =~ "5 | 4 | 64"

      html =
        lv
        |> form("#adjustment-form", adjustment: %{case_diff: "-2", piece_diff: "3", note: "x"})
        |> render_change()

      # 3 ケース、バラ 7、入数 12 → 総バラ 43
      assert html =~ "調整後: 3 | 7 | 43"
    end

    test "調整を登録するとロットが更新され、受払履歴に理由付きで残る", %{conn: conn, lot: lot, user: user} do
      {:ok, lv, _} = live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")

      lv
      |> form("#adjustment-form", adjustment: %{case_diff: "-1", piece_diff: "0", note: "破損"})
      |> render_submit()

      assert_redirect(lv, ~p"/inventory_lots/#{lot.id}")
      assert Repo.get!(InventoryLot, lot.id).case_qty == 4

      [tx | _] =
        Inventories.list_inventory_transactions(%{"transaction_type" => "adjust"}).entries

      assert {tx.note, tx.case_diff, tx.user_id} == {"破損", -1, user.id}
    end

    test "理由が無ければエラー", %{conn: conn, lot: lot} do
      {:ok, lv, _} = live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")

      html =
        lv
        |> form("#adjustment-form", adjustment: %{case_diff: "1", piece_diff: "0", note: ""})
        |> render_submit()

      assert html =~ "理由を入力してください"
      assert Repo.get!(InventoryLot, lot.id).case_qty == 5
    end

    test "有効在庫を下回る減算はエラー", %{conn: conn, lot: lot, user: user} do
      {:ok, _} =
        FoodVault.ShipmentOrders.allocate_shipment_order(user, %{
          warehouse_id: lot.warehouse_id,
          shipment_date: ~D[2026-11-15],
          lines: [%{item_id: lot.item_id, req_cases: 4}]
        })

      {:ok, lv, _} = live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")

      html =
        lv
        |> form("#adjustment-form", adjustment: %{case_diff: "-3", piece_diff: "0", note: "x"})
        |> render_submit()

      assert html =~ "有効在庫(現在庫 − 引当済)を下回る減算はできません"
      assert Repo.get!(InventoryLot, lot.id).case_qty == 5
    end

    test "荷まとめの換算で、ケース +k・バラ −k×入数 が入力欄に入る", %{conn: conn, lot: lot} do
      {:ok, lv, _} = live(conn, ~p"/management/inventory_lots/#{lot.id}/adjustments/new")

      html = lv |> form("#bundle-form", %{k: "2"}) |> render_submit()

      assert html =~ ~s(value="2")
      assert html =~ ~s(value="-24")
      assert html =~ ~s(value="荷まとめ")
    end
  end
end
