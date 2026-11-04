defmodule FoodShipWeb.UserSessionControllerTest do
  # Logger のレベルをテスト中だけ下げるため async: false
  use FoodShipWeb.ConnCase, async: false

  # info ログをテスト出力に漏らさない
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import FoodShip.AccountsFixtures

  alias FoodShip.Accounts

  @invalid "メールアドレスまたはパスワードが正しくありません。"

  setup do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)

    %{user: user_fixture(%{must_change_password: false})}
  end

  describe "POST /users/log_in" do
    test "メール＋パスワードでログインし、:log_in を記録する(パスワードは出さない)", %{conn: conn, user: user} do
      log =
        capture_log(fn ->
          conn =
            post(conn, ~p"/users/log_in", %{
              "user" => %{"email" => user.email, "password" => valid_user_password()}
            })

          assert get_session(conn, :user_token)
          assert redirected_to(conn) == ~p"/"
          assert Phoenix.Flash.get(conn.assigns.flash, :info) == "ログインしました。"
        end)

      assert log =~ "ログインしました。"
      assert log =~ "log_in" or log =~ "ログイン"
      refute log =~ valid_user_password()
    end

    test "元のページに戻る", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/management/users")
        |> post(~p"/users/log_in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/management/users"
    end

    test "remember me を指定すると cookie を書く", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_food_ship_web_user_remember_me"]
    end

    test "失敗時のエラーは 1 種類で、存在しないメール・誤パスワード・アーカイブ済みを区別しない", %{conn: conn, user: user} do
      archived = archived_user_fixture()

      for {email, password} <- [
            {user.email, "wrong password!!"},
            {"nobody@example.com", valid_user_password()},
            {archived.email, valid_user_password()}
          ] do
        log =
          capture_log(fn ->
            conn =
              post(conn, ~p"/users/log_in", %{
                "user" => %{"email" => email, "password" => password}
              })

            assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid
            assert redirected_to(conn) == ~p"/users/log_in"
            refute get_session(conn, :user_token)
          end)

        assert log =~ "ログインに失敗しました。"
        refute log =~ password
      end
    end

    test "不正なパラメータでも同じエラー", %{conn: conn} do
      conn = post(conn, ~p"/users/log_in", %{"foo" => "bar"})
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid
      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end

  describe "POST /users/update_password" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      conn = post(conn, ~p"/users/update_password", %{"user" => %{}})
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "パスワードを変更し、古いトークンを失効させて再ログインする", %{conn: conn, user: user} do
      old_token = Accounts.generate_user_session_token(user)
      conn = conn |> log_in_user(user) |> put_session(:user_token, old_token)

      conn =
        post(conn, ~p"/users/update_password", %{
          "user" => %{
            "current_password" => valid_user_password(),
            "password" => "brand new password",
            "password_confirmation" => "brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert new_token = get_session(conn, :user_token)
      refute new_token == old_token
      refute Accounts.get_user_by_session_token(old_token)
      assert Accounts.get_user_by_session_token(new_token)
      assert Accounts.get_user_by_email_and_password(user.email, "brand new password")
    end

    test "強制変更中のユーザーでも到達でき、変更後は must_change_password が false になる", %{conn: conn} do
      user = user_fixture()
      assert user.must_change_password

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update_password", %{
          "user" => %{
            "current_password" => valid_user_password(),
            "password" => "brand new password",
            "password_confirmation" => "brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user!(user.id).must_change_password
    end

    test "現在のパスワードが違うと変更されない", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update_password", %{
          "user" => %{
            "current_password" => "wrong password!!",
            "password" => "brand new password",
            "password_confirmation" => "brand new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/password"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "パスワードを変更できませんでした。"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "DELETE /users/log_out" do
    test "ログアウトしてトークンを失効させる", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user)
      token = get_session(conn, :user_token)
      conn = delete(conn, ~p"/users/log_out")

      assert redirected_to(conn) == ~p"/users/log_in"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "未ログインでも動く", %{conn: conn} do
      conn = delete(conn, ~p"/users/log_out")
      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end
end
