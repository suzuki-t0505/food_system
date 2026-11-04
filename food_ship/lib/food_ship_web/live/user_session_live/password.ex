defmodule FoodShipWeb.UserSessionLive.Password do
  @moduledoc "自分のパスワード変更(全ロール)。`must_change_password` の強制遷移先でもある。"

  use FoodShipWeb, :live_view

  alias FoodShip.Accounts
  alias FoodShip.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            パスワード変更
            <:subtitle :if={@current_scope.user.must_change_password}>
              初期(再設定)パスワードのままです。新しいパスワードに変更してください。
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="password_form"
          action={~p"/users/update_password"}
          method="post"
          phx-change="validate"
          phx-submit="save"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:current_password]}
            type="password"
            label="現在のパスワード"
            autocomplete="current-password"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="新しいパスワード(12文字以上)"
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="新しいパスワード(確認)"
            autocomplete="new-password"
            required
          />
          <.button class="btn btn-primary w-full" phx-disable-with="変更中...">
            パスワードを変更する
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    {:ok, assign(socket, form: to_form(changeset, as: "user"), trigger_submit: false)}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    if Permission.can?(user, :change_own_password) do
      changeset = Accounts.change_user_password(user, params, hash_password: false)

      case Ecto.Changeset.apply_action(changeset, :insert) do
        {:ok, _user} ->
          # 検証を通ったら、コントローラへ POST してセッションを作り直す
          {:noreply, assign(socket, trigger_submit: true)}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end
end
