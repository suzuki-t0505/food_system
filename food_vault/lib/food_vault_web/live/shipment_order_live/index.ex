defmodule FoodVaultWeb.ShipmentOrderLive.Index do
  @moduledoc "出庫オーダー一覧(全ロール参照)。状態・倉庫・出庫予定日・起源で絞り込む。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.{ShipmentOrders, Warehouses}
  alias FoodVault.ShipmentOrders.ShipmentOrder
  alias FoodVault.Utils.Permission

  @filter_keys ~w(status warehouse_id shipment_date origin)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        出庫オーダー
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_shipment_order)}
            navigate={~p"/shipment_orders/new"}
            class="btn btn-primary"
            id="new-shipment-order"
          >
            出庫オーダーを登録する
          </.link>
        </:actions>
      </.header>

      <.form
        for={@filter_form}
        id="filter-form"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          field={@filter_form[:status]}
          type="select"
          label="状態"
          prompt="すべて"
          options={for s <- ShipmentOrder.statuses(), do: {ShipmentOrder.status_label(s), s}}
        />
        <.input
          field={@filter_form[:warehouse_id]}
          type="select"
          label="倉庫"
          prompt="すべて"
          options={Enum.map(@warehouses, &{&1.warehouse_name, &1.id})}
        />
        <.input field={@filter_form[:shipment_date]} type="date" label="出庫予定日" />
        <.input
          field={@filter_form[:origin]}
          type="select"
          label="起源"
          prompt="すべて"
          options={[{"画面登録", "screen"}, {"発送システム", "external"}]}
        />
      </.form>

      <div class="overflow-x-auto">
        <table class="table table-sm" id="shipment-orders">
          <thead>
            <tr>
              <th>出庫予定日</th>
              <th>倉庫</th>
              <th>状態</th>
              <th>起源</th>
              <th>伝票 ID</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={order <- @page.entries} id={"order-#{order.id}"}>
              <td>{order.shipment_date}</td>
              <td>{order.warehouse.warehouse_name}</td>
              <td><span class="badge">{ShipmentOrder.status_label(order.status)}</span></td>
              <td>{ShipmentOrder.origin_label(ShipmentOrder.origin(order))}</td>
              <td>{order.external_slip_id}</td>
              <td class="text-right">
                <.link navigate={~p"/shipment_orders/#{order.id}"} class="btn btn-sm">詳細</.link>
              </td>
            </tr>
            <tr :if={@page.entries == []}>
              <td colspan="6" class="text-center text-base-content/60">出庫オーダーがありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} base_path={~p"/shipment_orders"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :warehouses, Warehouses.all_warehouses())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(:page, ShipmentOrders.list_shipment_orders(params))
     |> assign(:filter_form, to_form(params, as: :filter))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query =
      filter
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/shipment_orders?#{query}")}
  end
end
