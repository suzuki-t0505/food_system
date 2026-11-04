defmodule FoodShipWeb.UserSessionLive.Login do
  use FoodShipWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            ログイン
            <:subtitle>管理者に登録されたメールアドレスとパスワードでログインしてください。</:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="login_form"
          action={~p"/users/log_in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:email]}
            type="email"
            label="メールアドレス"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="パスワード"
            autocomplete="current-password"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:remember_me]}
            type="checkbox"
            label="ログインしたままにする"
          />
          <.button class="btn btn-primary w-full">
            ログイン <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      email = Phoenix.Flash.get(socket.assigns.flash, :email)
      form = to_form(%{"email" => email}, as: "user")

      {:ok, assign(socket, form: form, trigger_submit: false)}
    end
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
