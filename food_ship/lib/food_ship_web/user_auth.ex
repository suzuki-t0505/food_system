defmodule FoodShipWeb.UserAuth do
  @moduledoc """
  認証・認可の plug と LiveView の `on_mount`。

  `current_scope` を assign するのは、plug(`fetch_current_scope_for_user/2`)と
  `on_mount`(`mount_current_scope`)の 2 箇所のみ。認可は 3 層(plug・`on_mount`・
  イベント単位の `Permission.can?/2`)で行い、ロールの判定は `Permission` に一本化する。
  """

  use FoodShipWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias FoodShip.Accounts
  alias FoodShip.Accounts.{Scope, User}
  alias FoodShip.Utils.Permission

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_food_ship_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> delete_session(:user_return_to)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      FoodShipWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/users/log_in")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      FoodShipWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  LiveView で `current_scope` を assign し、認証・認可する。

  ## `on_mount` の引数

    * `:mount_current_scope` - `current_scope` を assign するだけ(ログイン画面用)
    * `:ensure_authenticated` - ログイン済み(全ロール)
    * `:ensure_authenticated_staff` - `staff` 以上
    * `:ensure_authenticated_admin` - `admin`
    * `:ensure_authenticated_for_password_change` - ログイン済み(全ロール)。
      `must_change_password` の強制遷移の対象外(パスワード変更画面専用)

  `:ensure_authenticated*`(パスワード変更画面用を除く)は、`must_change_password` が true の
  ユーザーを `/users/password` へ遷移させる。LiveView 間の遷移は plug を通らないため、
  `live_session` には plug と同じ強さの `on_mount` を必ず指定する。
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket),
    do: ensure_role(socket, session, :viewer, true)

  def on_mount(:ensure_authenticated_staff, _params, session, socket),
    do: ensure_role(socket, session, :staff, true)

  def on_mount(:ensure_authenticated_admin, _params, session, socket),
    do: ensure_role(socket, session, :admin, true)

  def on_mount(:ensure_authenticated_for_password_change, _params, session, socket),
    do: ensure_role(socket, session, :viewer, false)

  defp ensure_role(socket, session, role, enforce_password_change?) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %User{} = user} ->
        cond do
          enforce_password_change? and user.must_change_password ->
            {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/password")}

          not Permission.role_at_least?(user, role) ->
            {:halt,
             socket
             |> Phoenix.LiveView.put_flash(:error, "権限がありません。")
             |> Phoenix.LiveView.redirect(to: ~p"/")}

          true ->
            {:cont, socket}
        end

      _ ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "ログインしてください。")
         |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "ログイン後に遷移するパス。"
  def signed_in_path(_conn), do: ~p"/"

  @doc """
  ログイン済み(全ロール)を要求する plug。`must_change_password` が true なら
  `/users/password` へ遷移させる。
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns.current_scope do
      %Scope{user: %User{must_change_password: true}} ->
        conn |> redirect(to: ~p"/users/password") |> halt()

      %Scope{user: %User{}} ->
        conn

      _ ->
        deny_unauthenticated(conn)
    end
  end

  @doc """
  ログイン済み(全ロール)を要求する plug。`must_change_password` の強制遷移の対象外
  (パスワード変更の送信先専用)。
  """
  def require_logged_in_user(conn, _opts) do
    case conn.assigns.current_scope do
      %Scope{user: %User{}} -> conn
      _ -> deny_unauthenticated(conn)
    end
  end

  @doc "`staff` 以上を要求する plug。ログイン済みの確認と強制遷移も含む。"
  def require_authenticated_staff_user(conn, opts), do: require_role(conn, opts, :staff)

  @doc "`admin` を要求する plug。ログイン済みの確認と強制遷移も含む。"
  def require_authenticated_admin_user(conn, opts), do: require_role(conn, opts, :admin)

  defp require_role(conn, opts, role) do
    conn = require_authenticated_user(conn, opts)

    cond do
      conn.halted ->
        conn

      Permission.role_at_least?(conn.assigns.current_scope.user, role) ->
        conn

      true ->
        conn
        |> put_flash(:error, "権限がありません。")
        |> redirect(to: ~p"/")
        |> halt()
    end
  end

  defp deny_unauthenticated(conn) do
    conn
    |> put_flash(:error, "ログインしてください。")
    |> maybe_store_return_to()
    |> redirect(to: ~p"/users/log_in")
    |> halt()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
