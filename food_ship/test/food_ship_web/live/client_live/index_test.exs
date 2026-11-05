defmodule FoodShipWeb.ClientLive.IndexTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.Clients

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/masters/clients")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、編集ボタンは出ない", %{conn: conn} do
      client = client_fixture(%{client_name: "閲覧発注元"})
      {:ok, lv, html} = live(conn, ~p"/masters/clients")

      assert html =~ "閲覧発注元"
      refute has_element?(lv, "#new-client")
      refute has_element?(lv, "#edit-client-#{client.id}")
      refute has_element?(lv, "#archive-client-#{client.id}")
    end

    test "イベントを直接送ってもアーカイブできない", %{conn: conn} do
      client = client_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/clients")

      assert render_click(lv, "archive", %{"id" => client.id}) =~ "権限がありません。"
      refute Clients.get_client!(client.id).archived_at
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "復帰のイベントも拒否される", %{conn: conn} do
      client = client_fixture()
      {:ok, _} = Clients.archive_client(user_scope_fixture(), client)
      {:ok, lv, _} = live(conn, ~p"/masters/clients?include_archived=true")

      assert render_click(lv, "restore", %{"id" => client.id}) =~ "権限がありません。"
      assert Clients.get_client!(client.id).archived_at
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "アーカイブと復帰ができる", %{conn: conn} do
      client = client_fixture(%{client_name: "操作発注元"})
      {:ok, lv, _} = live(conn, ~p"/masters/clients")

      lv |> element("#archive-client-#{client.id}") |> render_click()
      assert Clients.get_client!(client.id).archived_at
      refute has_element?(lv, "#client-#{client.id}")

      lv |> element("#include-archived") |> render_click()
      assert_patch(lv)
      assert has_element?(lv, "#client-#{client.id}")

      lv |> element("#restore-client-#{client.id}") |> render_click()
      refute Clients.get_client!(client.id).archived_at
    end
  end
end
