defmodule FoodShipWeb.ShippingSlipLive.Index do
  @moduledoc """
  作業画面(出荷予定日別の伝票一覧)。単位 D で、タブ・フィルタ・操作を追加する。
  """

  use FoodShipWeb, :live_view

  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.Utils.ConvertDatetime
  alias FoodShipWeb.SlipMessages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        {@date} の伝票
      </.header>

      <div class="overflow-x-auto">
        <table class="table" id="shipping-slips">
          <thead>
            <tr>
              <th>伝票番号</th>
              <th>発注元</th>
              <th>商品</th>
              <th class="text-right">件数</th>
              <th class="text-right">バラ数</th>
              <th>状態</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={slip <- @slips} id={"slip-#{slip.id}"}>
              <td>{ShippingSlip.slip_no_label(slip)}</td>
              <td>{slip.client.client_name}</td>
              <td>{slip.shipping_item.item_name}</td>
              <td class="text-right">{slip.order_count}</td>
              <td class="text-right">{slip.total_piece_qty}</td>
              <td>
                {ShippingSlip.status_label(slip.status)}
                <span :if={SlipMessages.pending_message(slip)} class="block text-xs">
                  {SlipMessages.pending_message(slip)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    date =
      case Date.from_iso8601(params["date"] || "") do
        {:ok, date} -> date
        _ -> ConvertDatetime.today_jst()
      end

    {:noreply,
     socket |> assign(:date, date) |> assign(:slips, ShippingSlips.list_shipping_slips(date))}
  end
end
