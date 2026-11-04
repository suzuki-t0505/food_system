defmodule FoodVaultWeb.MakerLive.IndexTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Makers

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/masters/makers")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、編集ボタンは出ない", %{conn: conn} do
      maker = maker_fixture(%{maker_name: "閲覧メーカー"})
      {:ok, lv, html} = live(conn, ~p"/masters/makers")

      assert html =~ "閲覧メーカー"
      refute has_element?(lv, "#new-maker")
      refute has_element?(lv, "#edit-maker-#{maker.id}")
      refute has_element?(lv, "#archive-maker-#{maker.id}")
    end

    test "イベントを直接送ってもアーカイブできない", %{conn: conn} do
      maker = maker_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/makers")

      assert render_click(lv, "archive", %{"id" => maker.id}) =~ "権限がありません。"
      refute Makers.get_maker!(maker.id).archived_at
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "復帰のイベントも拒否される", %{conn: conn} do
      maker = maker_fixture()
      {:ok, _} = Makers.archive_maker(user_scope_fixture(), maker)
      {:ok, lv, _} = live(conn, ~p"/masters/makers?include_archived=true")

      assert render_click(lv, "restore", %{"id" => maker.id}) =~ "権限がありません。"
      assert Makers.get_maker!(maker.id).archived_at
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "アーカイブと復帰ができる", %{conn: conn} do
      maker = maker_fixture(%{maker_name: "操作メーカー"})
      {:ok, lv, _} = live(conn, ~p"/masters/makers")

      lv |> element("#archive-maker-#{maker.id}") |> render_click()
      assert Makers.get_maker!(maker.id).archived_at
      refute has_element?(lv, "#maker-#{maker.id}")

      lv |> element("#include-archived") |> render_click()
      assert_patch(lv)
      assert has_element?(lv, "#maker-#{maker.id}")

      lv |> element("#restore-maker-#{maker.id}") |> render_click()
      refute Makers.get_maker!(maker.id).archived_at
    end

    test "有効な商品があるメーカーはアーカイブできない", %{conn: conn} do
      maker = maker_fixture()
      item_fixture(%{maker_id: maker.id})
      {:ok, lv, _} = live(conn, ~p"/masters/makers")

      html = lv |> element("#archive-maker-#{maker.id}") |> render_click()
      assert html =~ "有効な商品があるため、アーカイブできません。"
      refute Makers.get_maker!(maker.id).archived_at
    end
  end
end
