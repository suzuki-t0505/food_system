defmodule FoodShipWeb.SlipComponents do
  @moduledoc "伝票の画面で共通に使う業務用コンポーネント。`core_components.ex` は改変しない。"

  use Phoenix.Component

  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}

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
end
