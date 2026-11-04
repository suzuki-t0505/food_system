defmodule FoodShipWeb.UserSessionLive.LoginTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "GET /users/log_in" do
    test "ログインフォームを表示する(自己登録・マジックリンクの導線は無い)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      assert html =~ "ログイン"
      assert html =~ "ログインしたままにする"
      refute html =~ "register"
      refute html =~ "Sign up"
    end

    test "ログイン済みは / へ遷移する", %{conn: conn} do
      user = user_fixture(%{must_change_password: false})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> log_in_user(user) |> live(~p"/users/log_in")
    end
  end

  describe "ログイン操作" do
    test "送信するとコントローラへ POST され、ログインできる", %{conn: conn} do
      user = user_fixture(%{must_change_password: false})
      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      form =
        form(lv, "#login_form", user: %{email: user.email, password: valid_user_password()})

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/"
    end

    test "失敗するとログイン画面に戻り、エラーは 1 種類", %{conn: conn} do
      user = user_fixture(%{must_change_password: false})
      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      form = form(lv, "#login_form", user: %{email: user.email, password: "wrong password!!"})
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/users/log_in"
      {:ok, _lv, html} = live(conn, ~p"/users/log_in")
      assert html =~ "メールアドレスまたはパスワードが正しくありません。"
    end
  end

  describe "未ログインのアクセス" do
    test "保護された画面はログイン画面へ遷移し、ログイン後に元のページへ戻る", %{conn: conn} do
      admin = admin_fixture()

      conn = get(conn, ~p"/management/users")
      assert redirected_to(conn) == ~p"/users/log_in"

      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      form =
        form(lv, "#login_form", user: %{email: admin.email, password: valid_user_password()})

      conn = submit_form(form, conn)
      assert redirected_to(conn) == "/management/users"
    end
  end
end
