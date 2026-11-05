defmodule FoodShipWeb.Management.ClientLive.FormTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.Clients

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, ~p"/management/clients/new")
    end

    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/clients/new")
      end
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "登録できる", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/clients/new")

      lv
      |> form("#client-form", client: %{client_code: "CL01", client_name: "新発注元"})
      |> render_submit()

      assert_redirect(lv, ~p"/masters/clients")
      assert Enum.any?(Clients.all_clients(), &(&1.client_code == "CL01"))
    end

    test "必須項目が空ならエラーを表示して保存しない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/clients/new")

      html =
        lv |> form("#client-form", client: %{client_code: "", client_name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Clients.all_clients() == []
    end

    test "コードの重複はエラー", %{conn: conn} do
      existing = client_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/clients/new")

      html =
        lv
        |> form("#client-form", client: %{client_code: existing.client_code, client_name: "重複"})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "編集できる", %{conn: conn} do
      client = client_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/clients/#{client.id}/edit")

      lv |> form("#client-form", client: %{client_name: "改名"}) |> render_submit()
      assert_redirect(lv, ~p"/masters/clients")
      assert Clients.get_client!(client.id).client_name == "改名"
    end
  end
end
