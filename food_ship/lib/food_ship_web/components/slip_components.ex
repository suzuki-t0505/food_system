defmodule FoodShipWeb.SlipComponents do
  @moduledoc "伝票の画面で共通に使う業務用コンポーネント。`core_components.ex` は改変しない。"

  use Phoenix.Component

  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}
  alias FoodShip.TotalPicks.TotalPick

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

  @pick_status_classes %{
    issued: "badge-success",
    outdated: "badge-warning",
    cancelled: "badge-neutral"
  }

  @doc "トータルピックの状態バッジ。"
  attr :status, :atom, required: true

  def pick_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", Map.fetch!(pick_status_classes(), @status)]}>
      {TotalPick.status_label(@status)}
    </span>
    """
  end

  defp pick_status_classes, do: @pick_status_classes

  @doc """
  ページ送り。`Scrivener.Page` を受け取り、`base_path` に `page` を足したリンクを出す。

  他のクエリ(`params`。文字列キー、空は除く)は引き継ぐ。1 ページしか無いときは何も出さない。
  """
  attr :page, :map, required: true
  attr :base_path, :string, required: true
  attr :params, :map, default: %{}

  def pagination(%{page: %{total_pages: total}} = assigns) when total <= 1 do
    ~H""
  end

  def pagination(assigns) do
    ~H"""
    <nav class="join" id="pagination">
      <.link
        :for={n <- 1..@page.total_pages}
        patch={page_path(@base_path, @params, n)}
        class={["join-item btn btn-sm", n == @page.page_number && "btn-active"]}
      >
        {n}
      </.link>
    </nav>
    """
  end

  defp page_path(base_path, params, n) do
    query =
      params
      |> Map.delete("page")
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()
      |> Map.put("page", n)
      |> URI.encode_query()

    base_path <> "?" <> query
  end

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
    "#{SlipAllocatedLot.expiration_label(lot.expiration_date)} × #{lot.allocated_pieces} 個"
  end
end
