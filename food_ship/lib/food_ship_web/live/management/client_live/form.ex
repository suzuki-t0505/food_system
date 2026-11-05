defmodule FoodShipWeb.Management.ClientLive.Form do
  @moduledoc "発注元の登録(`:new`)と編集(`:edit`)。`admin` のみ。"

  use FoodShipWeb, :live_view

  alias FoodShip.Clients
  alias FoodShip.Clients.Client
  alias FoodShip.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>{@page_title}</.header>

        <.form for={@form} id="client-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:client_code]} type="text" label="発注元コード" required />
          <.input field={@form[:client_name]} type="text" label="発注元名" required />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/clients"} class="btn">キャンセル</.link>
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
    socket
    |> assign(:page_title, "発注元を登録する")
    |> assign(:client, %Client{})
    |> assign_form(Clients.change_client(%Client{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    client = Clients.get_client!(id)

    socket
    |> assign(:page_title, "発注元を編集する")
    |> assign(:client, client)
    |> assign_form(Clients.change_client(client))
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      socket.assigns.client |> Clients.change_client(params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"client" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :new, params) do
    socket.assigns.current_scope
    |> Clients.create_client(params)
    |> handle_result(socket, "発注元を登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> Clients.update_client(socket.assigns.client, params)
    |> handle_result(socket, "発注元を更新しました。", :update)
  end

  defp handle_result({:ok, client}, socket, message, category) do
    OperationLog.info(socket, message, category, client)

    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/clients")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category),
    do: {:noreply, assign_form(socket, changeset)}

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: "client"))
end
