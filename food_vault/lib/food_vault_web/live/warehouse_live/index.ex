defmodule FoodVaultWeb.WarehouseLive.Index do
  @moduledoc "倉庫一覧(全ロール参照)。アーカイブ・復帰は `admin` のみ。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.Utils.Permission
  alias FoodVault.Warehouses
  alias FoodVault.Warehouses.Warehouse

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        倉庫
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/warehouses/new"}
            class="btn btn-primary"
            id="new-warehouse"
          >
            倉庫を登録する
          </.link>
        </:actions>
      </.header>

      <label class="label gap-2">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          id="include-archived"
          checked={@params["include_archived"] == "true"}
          phx-click="toggle_archived"
        /> アーカイブ済みも表示
      </label>

      <div class="overflow-x-auto">
        <table class="table" id="warehouses">
          <thead>
            <tr>
              <th>コード</th>
              <th>名称</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={warehouse <- @page.entries} id={"warehouse-#{warehouse.id}"}>
              <td>{warehouse.warehouse_code}</td>
              <td>{warehouse.warehouse_name}</td>
              <td><.archived_badge archived_at={warehouse.archived_at} /></td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/warehouses/#{warehouse.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-warehouse-#{warehouse.id}"}
                >
                  編集
                </.link>
                <button
                  :if={!Warehouse.archived?(warehouse)}
                  phx-click="archive"
                  phx-value-id={warehouse.id}
                  data-confirm="この倉庫をアーカイブします。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-warehouse-#{warehouse.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={Warehouse.archived?(warehouse)}
                  phx-click="restore"
                  phx-value-id={warehouse.id}
                  class="btn btn-sm"
                  id={"restore-warehouse-#{warehouse.id}"}
                >
                  復帰
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.pagination page={@page} base_path={~p"/masters/warehouses"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, params) |> assign_page()}
  end

  @impl true
  def handle_event("toggle_archived", _params, socket) do
    params =
      case socket.assigns.params do
        %{"include_archived" => "true"} = p -> Map.delete(p, "include_archived")
        p -> Map.put(p, "include_archived", "true")
      end

    {:noreply, push_patch(socket, to: ~p"/masters/warehouses?#{Map.delete(params, "page")}")}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    change(socket, id, &Warehouses.archive_warehouse/2, "倉庫をアーカイブしました。")
  end

  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, &Warehouses.restore_warehouse/2, "倉庫を復帰しました。")
  end

  defp change(socket, id, fun, message) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      case fun.(socket.assigns.current_scope, Warehouses.get_warehouse!(id)) do
        {:ok, warehouse} ->
          OperationLog.info(socket, message, :update, warehouse)
          {:noreply, socket |> put_flash(:info, message) |> assign_page()}

        {:error, :has_stock} ->
          {:noreply, put_flash(socket, :error, "在庫があるため、アーカイブできません。")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "変更できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp assign_page(socket),
    do: assign(socket, :page, Warehouses.list_warehouses(socket.assigns.params))
end
