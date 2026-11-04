defmodule FoodVaultWeb.Management.UserLive.Form do
  @moduledoc "ユーザー登録(`:new`)とパスワード再設定(`:reset_password`)。`admin` のみ。"

  use FoodVaultWeb, :live_view

  alias FoodVault.Accounts
  alias FoodVault.Accounts.User
  alias FoodVault.Utils.Permission
  alias FoodVaultWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>
          {@page_title}
          <:subtitle :if={@live_action == :reset_password}>
            {@user.name}({@user.email})のパスワードを再設定します。
            本人は次回ログイン時にパスワードの変更が必要になり、現在のセッションはすべて失効します。
          </:subtitle>
          <:subtitle :if={@live_action == :new}>
            初期パスワードを設定します。本人は初回ログイン時にパスワードの変更が必要です。
          </:subtitle>
        </.header>

        <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
          <.input :if={@live_action == :new} field={@form[:name]} type="text" label="名前" required />
          <.input
            :if={@live_action == :new}
            field={@form[:email]}
            type="email"
            label="メールアドレス"
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.input
            :if={@live_action == :new}
            field={@form[:role]}
            type="select"
            label="ロール"
            options={for role <- User.roles(), do: {User.role_label(role), role}}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="初期パスワード(12文字以上)"
            autocomplete="new-password"
            required
          />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/management/users"} class="btn">キャンセル</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    user = %User{}

    socket
    |> assign(:page_title, "ユーザーを登録する")
    |> assign(:user, user)
    |> assign_form(Accounts.change_user_creation(user, %{}, hash_password: false))
  end

  defp apply_action(socket, :reset_password, %{"id" => id}) do
    user = Accounts.get_user!(id)

    socket
    |> assign(:page_title, "パスワードを再設定する")
    |> assign(:user, user)
    |> assign_form(Accounts.change_user_reset_password(user, %{}, hash_password: false))
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      changeset(socket, params, hash_password: false, validate_unique: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_users) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :new, params) do
    case Accounts.create_user(socket.assigns.current_scope, params) do
      {:ok, user} ->
        OperationLog.info(socket, "ユーザーを登録しました。", :create, user)

        {:noreply,
         socket
         |> put_flash(:info, "ユーザーを登録しました。")
         |> push_navigate(to: ~p"/management/users")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :reset_password, params) do
    case Accounts.reset_user_password(socket.assigns.current_scope, socket.assigns.user, params) do
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)
        OperationLog.info(socket, "パスワードを再設定しました。", :update, user)

        {:noreply,
         socket
         |> put_flash(:info, "パスワードを再設定しました。")
         |> push_navigate(to: ~p"/management/users")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "自分自身のパスワードは「パスワード変更」から変更してください。")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp changeset(%{assigns: %{live_action: :new, user: user}}, params, opts),
    do: Accounts.change_user_creation(user, params, opts)

  defp changeset(%{assigns: %{live_action: :reset_password, user: user}}, params, opts),
    do: Accounts.change_user_reset_password(user, params, opts)

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: "user"))
end
