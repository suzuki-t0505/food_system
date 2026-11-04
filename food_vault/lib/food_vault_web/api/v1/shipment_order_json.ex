defmodule FoodVaultWeb.Api.V1.ShipmentOrderJSON do
  @moduledoc """
  出庫オーダーの JSON 表現。①②③⑤ の成功応答で共通の形を 1 か所に定義する。

  日付は ISO 8601、`status` は小文字 snake_case の文字列。引当ロットの `expiration_date` は
  ロットの期限日(期限なしの商品は `9999-12-31`)。
  """

  alias FoodVault.ShipmentOrders.ShipmentOrder

  @doc "1 件のオーダー(`order` は倉庫・明細・引当ロットを preload 済み)。"
  def show(%{order: order}), do: order(order)

  @doc "`external_slip_id` による照会の結果。"
  def index(%{orders: orders}), do: %{shipment_orders: Enum.map(orders, &order/1)}

  @doc false
  def order(%ShipmentOrder{} = order) do
    %{
      order_id: order.id,
      external_slip_id: order.external_slip_id,
      warehouse_id: order.warehouse_id,
      shipment_date: order.shipment_date,
      status: Atom.to_string(order.status),
      shipped_at: order.shipped_at,
      lines: Enum.map(order.lines, &line/1)
    }
  end

  defp line(line) do
    %{
      item_id: line.item_id,
      req_cases: line.req_cases,
      req_pieces: line.req_pieces,
      min_expiration_date: line.min_expiration_date,
      allocations: Enum.map(line.allocations, &allocation/1)
    }
  end

  defp allocation(allocation) do
    %{
      lot_id: allocation.lot_id,
      expiration_date: allocation.lot.expiration_date,
      allocated_cases: allocation.allocated_cases,
      allocated_pieces: allocation.allocated_pieces
    }
  end
end
