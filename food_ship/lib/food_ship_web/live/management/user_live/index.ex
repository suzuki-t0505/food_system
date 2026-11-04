defmodule FoodShipWeb.Management.UserLive.Index do
  @moduledoc "ユーザー管理の一覧(`admin` のみ)。ロール変更・アーカイブ・復帰。"

  use FoodShipWeb, :live_view

  alias FoodShip.Accounts
  alias FoodShip.Accounts.User
  alias FoodShip.Utils.Permission
  alias FoodShipWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        ユーザー管理
        <:actions>
          <.link navigate={~p"/management/users/new"} class="btn btn-primary" id="new-user">
            ユーザーを登録する
          </.link>
        </:actions>
      </.header>

      <div class="overflow-x-auto">
        <table class="table" id="users">
          <thead>
            <tr>
              <th>名前</th>
              <th>メールアドレス</th>
              <th>ロール</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @users} id={"user-#{user.id}"}>
              <td>{user.name}</td>
              <td>{user.email}</td>
              <td>
                <form
                  phx-change="change_role"
                  id={"role-form-#{user.id}"}
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <select
                    name="role"
                    class="select select-sm"
                    disabled={user.id == @current_scope.user.id or User.archived?(user)}
                  >
                    <option :for={role <- User.roles()} value={role} selected={user.role == role}>
                      {User.role_label(role)}
                    </option>
                  </select>
                </form>
              </td>
              <td>
                <span :if={User.archived?(user)} class="badge badge-neutral">アーカイブ済み</span>
                <span
                  :if={!User.archived?(user) and user.must_change_password}
                  class="badge badge-warning"
                >
                  パスワード変更待ち
                </span>
                <span
                  :if={!User.archived?(user) and !user.must_change_password}
                  class="badge badge-success"
                >
                  有効
                </span>
              </td>
              <td class="space-x-2 text-right">
                <.link
                  :if={user.id != @current_scope.user.id}
                  navigate={~p"/management/users/#{user.id}/reset_password"}
                  class="btn btn-sm"
                  id={"reset-password-#{user.id}"}
                >
                  パスワード再設定
                </.link>
                <button
                  :if={user.id != @current_scope.user.id and !User.archived?(user)}
                  phx-click="archive"
                  phx-value-id={user.id}
                  data-confirm="このユーザーをアーカイブします。ログインできなくなります。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-#{user.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={User.archived?(user)}
                  phx-click="restore"
                  phx-value-id={user.id}
                  class="btn btn-sm"
                  id={"restore-#{user.id}"}
                >
                  復帰
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :users, Accounts.list_users())}
  end

  @impl true
  def handle_event("change_role", %{"user_id" => id, "role" => role}, socket) do
    if allowed?(socket) do
      user = Accounts.get_user!(id)

      case Enum.find(User.roles(), &(Atom.to_string(&1) == role)) do
        nil ->
          {:noreply, put_flash(socket, :error, "ロールが正しくありません。")}

        role ->
          socket
          |> apply_result(
            Accounts.update_user_role(socket.assigns.current_scope, user, role),
            "ロールを変更しました。"
          )
          |> then(&{:noreply, &1})
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    if allowed?(socket) do
      user = Accounts.get_user!(id)

      socket
      |> apply_result(
        Accounts.archive_user(socket.assigns.current_scope, user),
        "ユーザーをアーカイブしました。"
      )
      |> then(&{:noreply, &1})
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    if allowed?(socket) do
      user = Accounts.get_user!(id)

      socket
      |> apply_result(
        Accounts.restore_user(socket.assigns.current_scope, user),
        "ユーザーを復帰しました。"
      )
      |> then(&{:noreply, &1})
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp allowed?(socket), do: Permission.can?(socket.assigns.current_scope.user, :manage_users)

  # 更新に成功したら全セッションを切断し、操作ログを残して一覧を読み直す
  defp apply_result(socket, {:ok, {user, expired_tokens}}, message) do
    UserAuth.disconnect_sessions(expired_tokens)
    OperationLog.info(socket, message, :update, user)
    refresh(socket, message)
  end

  defp apply_result(socket, {:ok, %User{} = user}, message) do
    OperationLog.info(socket, message, :update, user)
    refresh(socket, message)
  end

  defp apply_result(socket, {:error, :self}, _message),
    do: put_flash(socket, :error, "自分自身は変更できません。")

  defp apply_result(socket, {:error, :last_admin}, _message),
    do: put_flash(socket, :error, "最後の管理者は変更できません。")

  defp apply_result(socket, {:error, :forbidden}, _message),
    do: put_flash(socket, :error, "権限がありません。")

  defp apply_result(socket, {:error, %Ecto.Changeset{}}, _message),
    do: put_flash(socket, :error, "変更できませんでした。")

  defp refresh(socket, message) do
    socket
    |> assign(:users, Accounts.list_users())
    |> put_flash(:info, message)
  end
end
