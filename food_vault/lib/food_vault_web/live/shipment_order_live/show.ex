defmodule FoodVaultWeb.ShipmentOrderLive.Show do
  @moduledoc """
  出庫オーダーの詳細(全ロール参照)。引当ロット・オーダー履歴を表示し、
  `staff` 以上は画面登録のオーダーを出庫確定・引当解除(取消)できる。

  発送システム起源(`external_slip_id` あり)のオーダーは、画面からの確定・解除ができない
  (緊急操作 F-V8 は P1)。状態がずれる旨を警告として表示する。
  """

  use FoodVaultWeb, :live_view

  alias FoodVault.ShipmentOrders
  alias FoodVault.ShipmentOrders.{ShipmentOrder, ShipmentOrderEvent}
  alias FoodVault.Utils.{Calc, ConvertDatetime, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        出庫オーダー
        <:subtitle>
          {@order.warehouse.warehouse_name} / 出庫予定日 {@order.shipment_date}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/shipment_orders"} class="btn">一覧へ</.link>
          <button
            :if={@operable?}
            phx-click="ship"
            data-confirm="出庫を確定します。在庫が減ります。よろしいですか?"
            class="btn btn-primary"
            id="ship-order"
          >
            出庫確定
          </button>
          <button
            :if={@operable?}
            phx-click="cancel"
            data-confirm="引当を解除します。よろしいですか?"
            class="btn btn-error btn-soft"
            id="cancel-order"
          >
            引当解除
          </button>
        </:actions>
      </.header>

      <div :if={@external?} role="alert" class="alert alert-warning" id="external-warning">
        発送システムから登録されたオーダーです。この画面で確定・引当解除すると発送システムと状態がずれるため、操作できません。
      </div>

      <.list>
        <:item title="状態">{ShipmentOrder.status_label(@order.status)}</:item>
        <:item title="起源">{ShipmentOrder.origin_label(ShipmentOrder.origin(@order))}</:item>
        <:item :if={@order.external_slip_id} title="伝票 ID">{@order.external_slip_id}</:item>
        <:item :if={@order.shipped_at} title="出庫確定日時">
          {ConvertDatetime.format_jst(@order.shipped_at)}
        </:item>
      </.list>

      <h2 class="text-lg font-semibold">明細と引当ロット</h2>
      <div class="overflow-x-auto">
        <table class="table table-sm" id="order-lines">
          <thead>
            <tr>
              <th>商品</th>
              <th>要求(ケース | バラ)</th>
              <th>最低許容期限日</th>
              <th>引当ロット(期限日 × 数量)</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={line <- @order.lines} id={"line-#{line.id}"}>
              <td>{line.item.item_code} {line.item.item_name}</td>
              <td>{line.req_cases} | {line.req_pieces}</td>
              <td>{line.min_expiration_date}</td>
              <td>
                <ul>
                  <li :for={a <- line.allocations}>
                    <.link navigate={~p"/inventory_lots/#{a.lot_id}"} class="link">
                      {Calc.expiration_label(a.lot.expiration_date)}
                    </.link>
                    × {a.allocated_cases} ケース {a.allocated_pieces} バラ
                  </li>
                </ul>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="text-lg font-semibold">オーダー履歴</h2>
      <div class="overflow-x-auto">
        <table class="table table-sm" id="order-events">
          <thead>
            <tr>
              <th>日時</th>
              <th>種別</th>
              <th>理由</th>
              <th>操作者</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @order.events} id={"event-#{event.id}"}>
              <td>{ConvertDatetime.format_jst(event.inserted_at)}</td>
              <td>{ShipmentOrderEvent.event_type_label(event.event_type)}</td>
              <td>{event.reason}</td>
              <td>{(event.user && event.user.name) || event.operator}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign_order(socket, ShipmentOrders.get_shipment_order!(id))}
  end

  @impl true
  def handle_event("ship", _params, socket) do
    transition(socket, &ShipmentOrders.ship_shipment_order/2, "出庫を確定しました。")
  end

  def handle_event("cancel", _params, socket) do
    transition(socket, &ShipmentOrders.cancel_shipment_order/2, "引当を解除しました。")
  end

  defp transition(socket, fun, message) do
    user = socket.assigns.current_scope.user

    if Permission.can?(user, :manage_shipment_order) do
      user |> fun.(socket.assigns.order) |> handle_result(socket, message)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp handle_result({:ok, %{shipment_order: order, replayed?: replayed?}}, socket, message) do
    unless replayed?, do: OperationLog.info(socket, message, :update, order)
    {:noreply, socket |> put_flash(:info, message) |> assign_order(order)}
  end

  defp handle_result({:error, :invalid_state}, socket, _message) do
    order = ShipmentOrders.get_shipment_order!(socket.assigns.order.id)

    {:noreply,
     socket
     |> put_flash(:error, "このオーダーは現在の状態では操作できません。")
     |> assign_order(order)}
  end

  defp handle_result({:error, :forbidden}, socket, _message),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_order(socket, order) do
    user = socket.assigns.current_scope.user
    external? = ShipmentOrder.origin(order) == :external

    socket
    |> assign(:order, order)
    |> assign(:external?, external?)
    |> assign(
      :operable?,
      order.status == :allocated and not external? and
        Permission.can?(user, :manage_shipment_order)
    )
  end
end
