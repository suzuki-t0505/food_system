defmodule FoodShipWeb.SlipComponents do
  @moduledoc "伝票の画面で共通に使う業務用コンポーネント。`core_components.ex` は改変しない。"

  use Phoenix.Component

  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}
  alias FoodShipWeb.SlipMessages

  @status_classes %{
    pending: "badge-warning",
    allocated: "badge-info",
    shortage: "badge-error",
    packed: "badge-success",
    cancelled: "badge-neutral",
    reversed: "badge-neutral"
  }

  @doc "伝票の状態バッジ。"
  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", Map.fetch!(status_classes(), @status)]}>
      {ShippingSlip.status_label(@status)}
    </span>
    """
  end

  # モジュール属性のマップは型チェッカが警告するため、関数で返す
  defp status_classes, do: @status_classes

  @doc "引当ロットの「期限日 × 個数」(現場がピッキングする期限の目安)。期限なしは「期限なし」。"
  attr :lots, :list, required: true

  def allocated_lots(assigns) do
    ~H"""
    <ul class="text-sm">
      <li :for={lot <- @lots}>{lot_label(lot)}</li>
    </ul>
    """
  end

  @doc "引当ロット 1 行の表示(`2026-12-20 × 20 個`)。"
  def lot_label(%SlipAllocatedLot{} = lot) do
    expiration =
      if SlipAllocatedLot.no_expiration?(lot),
        do: "期限なし",
        else: Date.to_iso8601(lot.expiration_date)

    "#{expiration} × #{lot.allocated_pieces} 個"
  end

  ## 一括処理(取込後の引当・一括再引当・一括梱包完了)

  @kind_classes %{
    ok: "badge-success",
    shortage: "badge-error",
    pending: "badge-warning",
    error: "badge-error",
    waiting: "badge-ghost"
  }

  defp kind_classes, do: @kind_classes

  @doc """
  結果表(stream)の 1 行。`line` は CSV の行番号(取込以外は `nil`)、`outcome` は
  `SlipMessages.bulk_outcome/1` の戻り値か、処理前の `:waiting`。
  """
  def bulk_row(%ShippingSlip{} = slip, line, outcome) do
    {kind, text} =
      case outcome do
        :waiting -> {:waiting, "処理待ち"}
        outcome -> outcome
      end

    %{
      id: slip.id,
      line: line,
      slip_no: ShippingSlip.slip_no_label(slip),
      client_name: slip.client.client_name,
      item_name: "#{slip.shipping_item.item_code} #{slip.shipping_item.item_name}",
      ship_date: slip.scheduled_ship_date,
      order_count: slip.order_count,
      kind: kind,
      text: text
    }
  end

  @doc "一括処理の結果を、処理後の伝票とともに結果表の行にする。"
  def bulk_result_row(slip, line, result) do
    slip = result_slip(result) || slip
    bulk_row(slip, line, SlipMessages.bulk_outcome(result))
  end

  defp result_slip({:ok, %ShippingSlip{} = slip}), do: slip
  defp result_slip({:ok, %ShippingSlip{} = slip, _info}), do: slip
  defp result_slip(_result), do: nil

  @doc "一括処理の進捗(処理済み件数／全件)。"
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :done, :integer, required: true
  attr :total, :integer, required: true

  def bulk_progress(assigns) do
    assigns = assign(assigns, :max, max(assigns.total, 1))

    ~H"""
    <div id={@id} class="space-y-1" role="status">
      <p class="text-sm">{@label}: {@done} / {@total} 件</p>
      <progress class="progress progress-primary w-full" value={@done} max={@max}></progress>
    </div>
    """
  end

  @doc "一括処理の伝票ごとの結果表(`stream` を渡す)。"
  attr :id, :string, required: true
  attr :rows, :any, required: true, doc: "`stream` の値(`@streams.xxx`)"
  attr :show_line, :boolean, default: false, doc: "CSV の行番号の列を出す"

  def bulk_results(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm" id={@id}>
        <thead>
          <tr>
            <th :if={@show_line}>行</th>
            <th>伝票番号</th>
            <th>発注元</th>
            <th>商品</th>
            <th>出荷予定日</th>
            <th class="text-right">件数</th>
            <th>結果</th>
          </tr>
        </thead>
        <tbody id={"#{@id}-rows"} phx-update="stream">
          <tr :for={{dom_id, row} <- @rows} id={dom_id}>
            <td :if={@show_line}>{row.line}</td>
            <td class="whitespace-nowrap">{row.slip_no}</td>
            <td>{row.client_name}</td>
            <td>{row.item_name}</td>
            <td class="whitespace-nowrap">{row.ship_date}</td>
            <td class="text-right">{row.order_count}</td>
            <td>
              <span class={["badge badge-sm whitespace-nowrap", kind_class(row.kind)]}>
                {kind_label(row.kind)}
              </span>
              <span class="block text-xs">{row.text}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp kind_class(kind), do: Map.fetch!(kind_classes(), kind)

  defp kind_label(:ok), do: "成功"
  defp kind_label(:shortage), do: "在庫不足"
  defp kind_label(:pending), do: "引当待ち"
  defp kind_label(:error), do: "失敗"
  defp kind_label(:waiting), do: "処理待ち"
end
