defmodule FoodVaultWeb.Management.WarehouseLive.Form do
  @moduledoc "倉庫の登録(`:new`)と編集(`:edit`)。`admin` のみ。"

  use FoodVaultWeb, :live_view

  alias FoodVault.Utils.Permission
  alias FoodVault.Warehouses
  alias FoodVault.Warehouses.Warehouse

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>{@page_title}</.header>

        <.form for={@form} id="warehouse-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:warehouse_code]} type="text" label="倉庫コード" required />
          <.input field={@form[:warehouse_name]} type="text" label="倉庫名" required />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/warehouses"} class="btn">キャンセル</.link>
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
    |> assign(:page_title, "倉庫を登録する")
    |> assign(:warehouse, %Warehouse{})
    |> assign_form(Warehouses.change_warehouse(%Warehouse{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    warehouse = Warehouses.get_warehouse!(id)

    socket
    |> assign(:page_title, "倉庫を編集する")
    |> assign(:warehouse, warehouse)
    |> assign_form(Warehouses.change_warehouse(warehouse))
  end

  @impl true
  def handle_event("validate", %{"warehouse" => params}, socket) do
    changeset =
      socket.assigns.warehouse
      |> Warehouses.change_warehouse(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"warehouse" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :new, params) do
    socket.assigns.current_scope
    |> Warehouses.create_warehouse(params)
    |> handle_result(socket, "倉庫を登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> Warehouses.update_warehouse(socket.assigns.warehouse, params)
    |> handle_result(socket, "倉庫を更新しました。", :update)
  end

  defp handle_result({:ok, warehouse}, socket, message, category) do
    OperationLog.info(socket, message, category, warehouse)

    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/warehouses")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category),
    do: {:noreply, assign_form(socket, changeset)}

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: "warehouse"))
end
