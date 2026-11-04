defmodule FoodVaultWeb.ItemLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Items

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/masters/items")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧に入数と期限区分が出て、編集系は拒否される", %{conn: conn} do
      item = item_fixture(%{item_name: "閲覧商品", units_per_case: 24, expiration_type: :none})
      {:ok, lv, html} = live(conn, ~p"/masters/items")

      assert html =~ "閲覧商品"
      assert html =~ "管理なし"
      refute has_element?(lv, "#new-item")

      assert render_click(lv, "archive", %{"id" => item.id}) =~ "権限がありません。"
      refute Items.get_item!(item.id).archived_at
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "アーカイブと復帰ができる", %{conn: conn} do
      item = item_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/items")

      lv |> element("#archive-item-#{item.id}") |> render_click()
      assert Items.get_item!(item.id).archived_at

      lv |> element("#include-archived") |> render_click()
      assert_patch(lv)
      lv |> element("#restore-item-#{item.id}") |> render_click()
      refute Items.get_item!(item.id).archived_at
    end

    test "メーカーがアーカイブ済みの商品は復帰できない", %{conn: conn, scope: scope} do
      maker = maker_fixture()
      item = item_fixture(%{maker_id: maker.id})
      {:ok, _} = Items.archive_item(scope, item)
      {:ok, _} = FoodVault.Makers.archive_maker(scope, maker)

      {:ok, lv, _} = live(conn, ~p"/masters/items?include_archived=true")
      html = lv |> element("#restore-item-#{item.id}") |> render_click()

      assert html =~ "メーカーがアーカイブ済みのため、復帰できません。"
    end
  end
end
