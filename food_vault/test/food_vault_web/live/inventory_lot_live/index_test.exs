defmodule FoodVaultWeb.InventoryLotLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/inventory_lots")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "在庫を見られるが、入荷登録のリンクは出ない", %{conn: conn} do
      lot = lot_fixture(%{case_qty: 2, piece_qty: 5})
      {:ok, lv, html} = live(conn, ~p"/inventory_lots")

      assert has_element?(lv, "#lot-#{lot.id}")
      # 2 ケース × 12 + 5 = 29。ケース | バラ | 総バラ の 3 列表記
      assert html =~ "2 | 5 | 29"
      assert html =~ "2027-01-01"
      refute has_element?(lv, "#new-receipt")
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "入荷登録のリンクが出る", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/inventory_lots")
      assert has_element?(lv, "#new-receipt")
    end

    test "期限なしは「期限なし」と表示される", %{conn: conn} do
      item = item_fixture(%{expiration_type: :none})
      lot = lot_fixture(%{item_id: item.id, expiration_date: ~D[9999-12-31]})
      {:ok, lv, _} = live(conn, ~p"/inventory_lots")

      assert has_element?(lv, "#lot-#{lot.id}", "期限なし")
    end

    test "期限の近い順に並び、商品で絞り込める", %{conn: conn} do
      item = item_fixture()
      far = lot_fixture(%{item_id: item.id, expiration_date: ~D[2027-06-01]})
      near = lot_fixture(%{item_id: item.id, expiration_date: ~D[2027-02-01]})
      other = lot_fixture()

      {:ok, lv, html} = live(conn, ~p"/inventory_lots")
      {near_pos, _} = :binary.match(html, "lot-#{near.id}")
      {far_pos, _} = :binary.match(html, "lot-#{far.id}")
      assert near_pos < far_pos

      lv |> form("#filter-form", filter: %{item_id: other.item_id}) |> render_change()
      assert_patch(lv)

      assert has_element?(lv, "#lot-#{other.id}")
      refute has_element?(lv, "#lot-#{far.id}")
    end

    test "在庫 0 は既定で非表示、チェックで表示される", %{conn: conn} do
      lot = lot_fixture()
      lot |> Ecto.Changeset.change(case_qty: 0) |> FoodVault.Repo.update!()

      {:ok, lv, _} = live(conn, ~p"/inventory_lots")
      refute has_element?(lv, "#lot-#{lot.id}")

      lv |> form("#filter-form", filter: %{include_empty: "true"}) |> render_change()
      assert_patch(lv)
      assert has_element?(lv, "#lot-#{lot.id}")
    end

    test "商品別の表示に切り替えられる", %{conn: conn} do
      item = item_fixture()
      w = warehouse_fixture()
      lot_fixture(%{item_id: item.id, warehouse_id: w.id, case_qty: 1, piece_qty: 1})

      lot_fixture(%{
        item_id: item.id,
        warehouse_id: w.id,
        case_qty: 2,
        piece_qty: 2,
        expiration_date: ~D[2027-05-01]
      })

      {:ok, lv, _} = live(conn, ~p"/inventory_lots")
      lv |> form("#filter-form", filter: %{view: "summary"}) |> render_change()
      assert_patch(lv)

      assert has_element?(lv, "#summary-#{w.id}-#{item.id}", "3 | 3 | 39")
    end
  end
end
