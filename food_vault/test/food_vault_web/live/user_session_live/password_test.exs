defmodule FoodVaultWeb.UserSessionLive.PasswordTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Accounts

  describe "GET /users/password" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/users/password")
    end

    test "全ロールが開ける", %{conn: conn} do
      for role <- [:viewer, :staff, :admin] do
        user = user_fixture(%{role: role, must_change_password: false})
        {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/users/password")
        assert html =~ "パスワード変更"
        refute html =~ "初期(再設定)パスワードのままです"
      end
    end

    test "強制変更中はその旨を表示し、他の画面へ進めない", %{conn: conn} do
      user = user_fixture(%{role: :admin})
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/users/password")
      assert html =~ "初期(再設定)パスワードのままです"

      assert redirected_to(get(conn, ~p"/")) == ~p"/users/password"
      assert redirected_to(get(conn, ~p"/management/users")) == ~p"/users/password"

      assert {:error, {:redirect, %{to: "/users/password"}}} = live(conn, ~p"/management/users")
    end
  end

  describe "変更フォーム" do
    setup %{conn: conn} do
      user = user_fixture(%{must_change_password: false})
      %{conn: log_in_user(conn, user), user: user}
    end

    test "検証エラーを表示する", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/password")

      html =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "current_password" => "x",
            "password" => "short",
            "password_confirmation" => "different"
          }
        })

      assert html =~ "12文字以上"
      assert html =~ "が一致しません。"
    end

    test "現在のパスワードが違うと送信されない", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/password")

      html =
        lv
        |> form("#password_form",
          user: %{
            current_password: "wrong password!!",
            password: "brand new password",
            password_confirmation: "brand new password"
          }
        )
        |> render_submit()

      assert html =~ "が正しくありません。"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "正しく入力して送信するとコントローラ経由で変更される", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/password")

      form =
        form(lv, "#password_form",
          user: %{
            current_password: valid_user_password(),
            password: "brand new password",
            password_confirmation: "brand new password"
          }
        )

      render_submit(form)
      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/"
      assert Accounts.get_user_by_email_and_password(user.email, "brand new password")
    end
  end
end
