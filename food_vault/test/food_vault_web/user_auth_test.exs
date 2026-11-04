defmodule FoodVaultWeb.UserAuthTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures

  alias FoodVault.Accounts
  alias FoodVault.Accounts.Scope
  alias FoodVaultWeb.UserAuth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, FoodVaultWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: user_fixture(%{must_change_password: false}), conn: conn}
  end

  describe "log_in_user/3" do
    test "セッションにトークンを入れ、/ へ遷移する", %{conn: conn, user: user} do
      conn = conn |> fetch_flash() |> UserAuth.log_in_user(user)
      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(token)
    end

    test "user_return_to があればそこへ戻る", %{conn: conn, user: user} do
      conn =
        conn |> put_session(:user_return_to, "/management/users") |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == "/management/users"
    end

    test "remember_me を指定すると cookie を書く", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies["_food_vault_web_user_remember_me"]

      assert %{max_age: max_age, same_site: "Lax"} =
               conn.resp_cookies["_food_vault_web_user_remember_me"]

      assert max_age == 14 * 24 * 60 * 60
    end

    test "remember_me 指定がなければ cookie を書かない", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user)
      refute Map.has_key?(conn.resp_cookies, "_food_vault_web_user_remember_me")
    end
  end

  describe "log_out_user/1" do
    test "トークンと cookie を消し、ログイン画面へ戻る", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, token)
        |> put_req_cookie("_food_vault_web_user_remember_me", token)
        |> fetch_cookies()
        |> UserAuth.log_out_user()

      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies["_food_vault_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/users/log_in"
      refute Accounts.get_user_by_session_token(token)
    end

    test "ログインしていなくても動く", %{conn: conn} do
      conn = conn |> fetch_cookies() |> UserAuth.log_out_user()
      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "セッションのトークンから current_scope を assign する", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
      assert conn.assigns.current_scope.user.id == user.id
    end

    test "remember me cookie からも取得する", %{conn: conn, user: user} do
      logged_in_conn =
        conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      user_token = logged_in_conn.cookies["_food_vault_web_user_remember_me"]
      %{value: signed_token} = logged_in_conn.resp_cookies["_food_vault_web_user_remember_me"]

      conn =
        conn
        |> put_req_cookie("_food_vault_web_user_remember_me", signed_token)
        |> fetch_cookies()
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert get_session(conn, :user_token) == user_token
    end

    test "トークンが無ければ current_scope は nil", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope == nil
    end

    test "アーカイブ済みユーザーのトークンは無効", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      FoodVault.Repo.update!(FoodVault.Accounts.User.archive_changeset(user))

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
      assert conn.assigns.current_scope == nil
    end
  end

  describe "require_authenticated_user/2" do
    test "未ログインは GET のパスを保存してログイン画面へ", %{conn: conn} do
      conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz", method: "GET"}
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == "/foo?bar=baz"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "ログインしてください。"
    end

    test "GET 以外ではパスを保存しない", %{conn: conn} do
      conn =
        %{conn | method: "POST"}
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      refute get_session(conn, :user_return_to)
    end

    test "ログイン済みは通す", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "must_change_password が true なら /users/password へ遷移させる", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/password"
    end
  end

  describe "require_logged_in_user/2" do
    test "must_change_password が true でも通す", %{conn: conn} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user_fixture()))
        |> UserAuth.require_logged_in_user([])

      refute conn.halted
    end

    test "未ログインはログイン画面へ", %{conn: conn} do
      conn =
        conn
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_logged_in_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end

  describe "require_authenticated_admin_user/2" do
    for {role, allowed?} <- [admin: true, staff: false, viewer: false] do
      test "#{role}: #{if allowed?, do: "通す", else: "拒否して / へ"}", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        conn =
          conn
          |> fetch_flash()
          |> assign(:current_scope, Scope.for_user(user))
          |> UserAuth.require_authenticated_admin_user([])

        if unquote(allowed?) do
          refute conn.halted
        else
          assert conn.halted
          assert redirected_to(conn) == ~p"/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) == "権限がありません。"
        end
      end
    end

    test "未ログインはログイン画面へ", %{conn: conn} do
      conn =
        conn
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_authenticated_admin_user([])

      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "admin でも must_change_password が true なら /users/password へ", %{conn: conn} do
      user = user_fixture(%{role: :admin})

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_admin_user([])

      assert redirected_to(conn) == ~p"/users/password"
    end
  end

  describe "on_mount" do
    setup %{user: user} do
      %{token: Accounts.generate_user_session_token(user)}
    end

    defp socket,
      do: %Phoenix.LiveView.Socket{
        endpoint: FoodVaultWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

    test ":mount_current_scope は current_scope を assign する", %{token: token, user: user} do
      {:cont, socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, %{"user_token" => token}, socket())

      assert socket.assigns.current_scope.user.id == user.id
    end

    test ":mount_current_scope はトークンが無ければ nil", _ do
      {:cont, socket} = UserAuth.on_mount(:mount_current_scope, %{}, %{}, socket())
      assert socket.assigns.current_scope == nil
    end

    test ":ensure_authenticated はログイン済みを通す", %{token: token} do
      assert {:cont, _} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{"user_token" => token}, socket())
    end

    test ":ensure_authenticated は未ログインを拒否する" do
      assert {:halt, socket} = UserAuth.on_mount(:ensure_authenticated, %{}, %{}, socket())
      assert socket.redirected == {:redirect, %{to: ~p"/users/log_in", status: 302}}
    end

    test "must_change_password が true の場合は /users/password へ遷移させる" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      for hook <- [
            :ensure_authenticated,
            :ensure_authenticated_staff,
            :ensure_authenticated_admin
          ] do
        assert {:halt, socket} = UserAuth.on_mount(hook, %{}, %{"user_token" => token}, socket())
        assert socket.redirected == {:redirect, %{to: ~p"/users/password", status: 302}}
      end

      assert {:cont, _} =
               UserAuth.on_mount(
                 :ensure_authenticated_for_password_change,
                 %{},
                 %{"user_token" => token},
                 socket()
               )
    end

    test "ロール別に staff / admin を許可・拒否する" do
      for {role, staff_ok?, admin_ok?} <- [
            {:admin, true, true},
            {:staff, true, false},
            {:viewer, false, false}
          ] do
        user = user_fixture(%{role: role, must_change_password: false})
        session = %{"user_token" => Accounts.generate_user_session_token(user)}

        assert on_mount_result(:ensure_authenticated_staff, session) == staff_ok?
        assert on_mount_result(:ensure_authenticated_admin, session) == admin_ok?
      end
    end

    defp on_mount_result(hook, session) do
      case UserAuth.on_mount(hook, %{}, session, socket()) do
        {:cont, _} ->
          true

        {:halt, socket} ->
          assert socket.redirected == {:redirect, %{to: ~p"/", status: 302}}
          false
      end
    end
  end

  describe "disconnect_sessions/1" do
    test "トークンごとの live_socket_id に disconnect を送る" do
      Phoenix.PubSub.subscribe(FoodVault.PubSub, "users_sessions:abcd")

      UserAuth.disconnect_sessions([%{token: Base.url_decode64!("abcd")}])
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "users_sessions:abcd"}
    end
  end
end
