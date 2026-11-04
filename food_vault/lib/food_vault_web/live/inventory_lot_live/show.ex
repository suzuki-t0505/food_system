defmodule FoodVaultWeb.InventoryLotLive.Show do
  @moduledoc "ロット詳細(全ロール参照)。数量と直近の受払履歴を表示する。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.{Inventories, ShipmentOrders}
  alias FoodVault.Inventories.InventoryTransaction
  alias FoodVault.ShipmentOrders.ShipmentOrder
  alias FoodVault.Utils.{Calc, ConvertDatetime, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        ロット詳細
        <:subtitle>
          {@lot.item.item_code} {@lot.item.item_name}({@lot.warehouse.warehouse_name})
        </:subtitle>
        <:actions>
          <.link navigate={~p"/inventory_lots"} class="btn">在庫一覧へ</.link>
          <.link
            :if={Permission.can?(@current_scope.user, :adjust_inventory)}
            navigate={~p"/management/inventory_lots/#{@lot.id}/adjustments/new"}
            class="btn btn-primary"
            id="new-adjustment"
          >
            棚卸調整
          </.link>
        </:actions>
      </.header>

      <.list>
        <:item title="メーカー">{@lot.item.maker.maker_name}</:item>
        <:item title="ケース入数">{@lot.item.units_per_case}</:item>
        <:item title="期限日">{Calc.expiration_label(@lot.expiration_date)}</:item>
        <:item title="入荷日">{@lot.received_date}</:item>
        <:item title="在庫(ケース | バラ | 総バラ)">
          {quantity_text(@lot.case_qty, @lot.piece_qty, @lot.item.units_per_case)}
        </:item>
        <:item title="引当済">
          {quantity_text(@lot.allocated_case_qty, @lot.allocated_piece_qty, @lot.item.units_per_case)}
        </:item>
        <:item title="有効在庫">
          <% eff = Calc.effective(@lot) %>
          {quantity_text(eff.cases, eff.pieces, @lot.item.units_per_case)}
        </:item>
      </.list>

      <h2 class="text-lg font-semibold">このロットを引き当てているオーダー</h2>
      <div class="overflow-x-auto">
        <table class="table table-sm" id="allocating-orders">
          <thead>
            <tr>
              <th>出庫予定日</th>
              <th>倉庫</th>
              <th>起源</th>
              <th class="text-right">ケース</th>
              <th class="text-right">バラ</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{order, _item_id, cases, pieces} <- @allocating_orders}
              id={"allocating-#{order.id}"}
            >
              <td>{order.shipment_date}</td>
              <td>{order.warehouse.warehouse_name}</td>
              <td>{ShipmentOrder.origin_label(ShipmentOrder.origin(order))}</td>
              <td class="text-right">{cases}</td>
              <td class="text-right">{pieces}</td>
              <td class="text-right">
                <.link navigate={~p"/shipment_orders/#{order.id}"} class="btn btn-sm">詳細</.link>
              </td>
            </tr>
            <tr :if={@allocating_orders == []}>
              <td colspan="6" class="text-center text-base-content/60">引当中のオーダーはありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="text-lg font-semibold">受払履歴(直近 10 件)</h2>
      <div class="overflow-x-auto">
        <table class="table table-sm" id="lot-transactions">
          <thead>
            <tr>
              <th>日時</th>
              <th>区分</th>
              <th class="text-right">ケース</th>
              <th class="text-right">バラ</th>
              <th>備考</th>
              <th>操作者</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={tx <- @transactions} id={"transaction-#{tx.id}"}>
              <td>{ConvertDatetime.format_jst(tx.inserted_at)}</td>
              <td>{InventoryTransaction.transaction_type_label(tx.transaction_type)}</td>
              <td class="text-right">{tx.case_diff}</td>
              <td class="text-right">{tx.piece_diff}</td>
              <td>{tx.note}</td>
              <td>{(tx.user && tx.user.name) || tx.operator}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    lot = Inventories.get_inventory_lot!(id)

    transactions =
      Inventories.list_inventory_transactions(%{"lot_id" => lot.id, "page_size" => 10}).entries

    {:ok,
     assign(socket,
       lot: lot,
       transactions: transactions,
       allocating_orders: ShipmentOrders.list_allocating_orders(lot.id)
     )}
  end
end
