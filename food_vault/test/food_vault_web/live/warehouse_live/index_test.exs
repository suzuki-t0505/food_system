defmodule FoodVaultWeb.WarehouseLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Warehouses

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/masters/warehouses")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、編集ボタンは出ず、イベントも拒否される", %{conn: conn} do
      warehouse = warehouse_fixture(%{warehouse_name: "閲覧倉庫"})
      {:ok, lv, html} = live(conn, ~p"/masters/warehouses")

      assert html =~ "閲覧倉庫"
      refute has_element?(lv, "#new-warehouse")
      refute has_element?(lv, "#archive-warehouse-#{warehouse.id}")

      assert render_click(lv, "archive", %{"id" => warehouse.id}) =~ "権限がありません。"
      refute Warehouses.get_warehouse!(warehouse.id).archived_at
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "アーカイブと復帰ができる", %{conn: conn} do
      warehouse = warehouse_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/warehouses")

      lv |> element("#archive-warehouse-#{warehouse.id}") |> render_click()
      assert Warehouses.get_warehouse!(warehouse.id).archived_at

      lv |> element("#include-archived") |> render_click()
      assert_patch(lv)
      lv |> element("#restore-warehouse-#{warehouse.id}") |> render_click()
      refute Warehouses.get_warehouse!(warehouse.id).archived_at
    end
  end
end
