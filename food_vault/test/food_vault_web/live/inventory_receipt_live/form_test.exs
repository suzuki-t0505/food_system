defmodule FoodVaultWeb.InventoryReceiptLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Inventories
  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.Repo

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/inventory_receipts/new")
  end

  test "viewer は入れない", %{conn: conn} do
    user = user_fixture(%{role: :viewer, must_change_password: false})

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
             conn |> log_in_user(user) |> live(~p"/inventory_receipts/new")
  end

  for role <- [:staff, :admin] do
    describe "#{role}" do
      @describetag role: role
      setup :register_and_log_in_user

      setup do
        %{warehouse: warehouse_fixture(), item: item_fixture(%{units_per_case: 12})}
      end

      test "ケース数・バラ数から総バラ数がリアルタイムに表示される", %{conn: conn, warehouse: w, item: item} do
        {:ok, lv, html} = live(conn, ~p"/inventory_receipts/new")
        assert html =~ "総数:0 個"

        html =
          lv
          |> form("#receipt-form",
            receipt: %{warehouse_id: w.id, item_id: item.id, case_qty: "2", piece_qty: "3"}
          )
          |> render_change()

        assert html =~ "総数:27 個"
        assert html =~ "ケース入数 12"
      end

      test "期限なしの商品は期限日の欄が「期限なし」になる", %{conn: conn, warehouse: w} do
        none = item_fixture(%{expiration_type: :none})
        {:ok, lv, _} = live(conn, ~p"/inventory_receipts/new")

        lv
        |> form("#receipt-form", receipt: %{warehouse_id: w.id, item_id: none.id})
        |> render_change()

        assert has_element?(lv, "#no-expiration", "期限なし")
        refute has_element?(lv, "input[name='receipt[expiration_date]']")
      end

      test "入荷を登録するとロットと受払履歴ができ、ロット詳細へ遷移する", %{conn: conn, user: user, warehouse: w, item: item} do
        {:ok, lv, _} = live(conn, ~p"/inventory_receipts/new")

        lv
        |> form("#receipt-form",
          receipt: %{
            warehouse_id: w.id,
            item_id: item.id,
            expiration_date: "2027-03-01",
            received_date: "2026-11-02",
            case_qty: "2",
            piece_qty: "5"
          }
        )
        |> render_submit()

        lot = Repo.one!(InventoryLot)
        assert_redirect(lv, ~p"/inventory_lots/#{lot.id}")
        assert lot.case_qty == 2 and lot.piece_qty == 5
        assert lot.expiration_date == ~D[2027-03-01]

        [tx] = Inventories.list_inventory_transactions(%{"lot_id" => lot.id}).entries
        assert tx.transaction_type == :receive
        assert tx.user_id == user.id
      end

      test "期限日が無ければエラーを表示して登録しない", %{conn: conn, warehouse: w, item: item} do
        {:ok, lv, _} = live(conn, ~p"/inventory_receipts/new")

        html =
          lv
          |> form("#receipt-form",
            receipt: %{warehouse_id: w.id, item_id: item.id, case_qty: "1"}
          )
          |> render_submit()

        assert html =~ "期限日を入力してください"
        assert Repo.aggregate(InventoryLot, :count) == 0
      end

      test "数量が 0 のままならエラー", %{conn: conn, warehouse: w, item: item} do
        {:ok, lv, _} = live(conn, ~p"/inventory_receipts/new")

        html =
          lv
          |> form("#receipt-form",
            receipt: %{warehouse_id: w.id, item_id: item.id, expiration_date: "2027-03-01"}
          )
          |> render_submit()

        assert html =~ "ケース数かバラ数のどちらかは 1 以上にしてください"
      end
    end
  end
end
