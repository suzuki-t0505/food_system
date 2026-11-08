defmodule FoodVaultWeb.WarehouseLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures, only: [user_scope_fixture: 0]
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

      refute has_element?(lv, "#set-default-#{warehouse.id}")

      assert render_click(lv, "archive", %{"id" => warehouse.id}) =~ "権限がありません。"
      refute Warehouses.get_warehouse!(warehouse.id).archived_at

      assert render_click(lv, "set_default", %{"id" => warehouse.id}) =~ "権限がありません。"
      refute Warehouses.get_warehouse!(warehouse.id).is_default
    end

    test "デフォルト倉庫にはバッジが出る", %{conn: conn} do
      warehouse = warehouse_fixture()
      {:ok, _} = Warehouses.set_default_warehouse(user_scope_fixture(), warehouse)

      {:ok, lv, _} = live(conn, ~p"/masters/warehouses")

      assert has_element?(lv, "#default-badge-#{warehouse.id}", "デフォルト")
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

    test "デフォルト倉庫を設定・切り替えできる", %{conn: conn} do
      first = warehouse_fixture()
      second = warehouse_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/warehouses")

      lv |> element("#set-default-#{first.id}") |> render_click()
      assert Warehouses.get_default_warehouse().id == first.id
      assert has_element?(lv, "#default-badge-#{first.id}")
      refute has_element?(lv, "#set-default-#{first.id}")
      refute has_element?(lv, "#archive-warehouse-#{first.id}")

      lv |> element("#set-default-#{second.id}") |> render_click()
      assert Warehouses.get_default_warehouse().id == second.id
      refute has_element?(lv, "#default-badge-#{first.id}")
      assert has_element?(lv, "#default-badge-#{second.id}")
    end

    test "デフォルト倉庫のアーカイブとアーカイブ済みのデフォルト化は拒否される", %{conn: conn} do
      default = warehouse_fixture()
      archived = warehouse_fixture()
      scope = user_scope_fixture()
      {:ok, _} = Warehouses.set_default_warehouse(scope, default)
      {:ok, _} = Warehouses.archive_warehouse(scope, archived)
      {:ok, lv, _} = live(conn, ~p"/masters/warehouses")

      assert render_click(lv, "archive", %{"id" => default.id}) =~
               "デフォルト倉庫はアーカイブできません。"

      refute Warehouses.get_warehouse!(default.id).archived_at

      assert render_click(lv, "set_default", %{"id" => archived.id}) =~
               "アーカイブ済みの倉庫はデフォルトにできません。"

      refute Warehouses.get_warehouse!(archived.id).is_default
    end
  end
end
