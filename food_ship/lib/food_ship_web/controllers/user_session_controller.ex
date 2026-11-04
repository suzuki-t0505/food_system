defmodule FoodShipWeb.UserSessionController do
  use FoodShipWeb, :controller

  alias FoodShip.Accounts
  alias FoodShipWeb.UserAuth

  @invalid_credentials "メールアドレスまたはパスワードが正しくありません。"

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        # ユーザー列挙を防ぐため、メールの存在・アーカイブ済みかどうかは区別しない
        Logger.warning("ログインに失敗しました。", :log_in, %{email: String.slice(email, 0, 160)})

        conn
        |> put_flash(:error, @invalid_credentials)
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log_in")

      user ->
        Logger.info("ログインしました。", :log_in, %{user_id: user.id})

        conn
        |> put_flash(:info, "ログインしました。")
        |> UserAuth.log_in_user(user, user_params)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, @invalid_credentials)
    |> redirect(to: ~p"/users/log_in")
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, expired_tokens}} ->
        # 古いセッションの LiveView をすべて切断する
        UserAuth.disconnect_sessions(expired_tokens)
        OperationLog.info(conn, "パスワードを変更しました。", :update, user)

        conn
        |> put_flash(:info, "パスワードを変更しました。")
        |> put_session(:user_return_to, ~p"/")
        |> UserAuth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "パスワードを変更できませんでした。")
        |> redirect(to: ~p"/users/password")
    end
  end

  def update_password(conn, _params) do
    redirect(conn, to: ~p"/users/password")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "ログアウトしました。")
    |> UserAuth.log_out_user()
  end
end
