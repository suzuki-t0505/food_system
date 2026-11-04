defmodule FoodVaultWeb.InventoryComponents do
  @moduledoc "在庫・マスタ画面で共通に使う業務用コンポーネント。`core_components.ex` は改変しない。"

  use Phoenix.Component

  alias FoodVault.Utils.Calc

  @doc """
  ページ送り。`Scrivener.Page` を受け取り、`base_path` に `page` を足したリンクを出す。

  他のクエリ(`params`)は引き継ぐ。1 ページしか無いときは何も出さない。
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
    query = params |> Map.take(["include_archived"]) |> Map.put("page", n) |> URI.encode_query()
    base_path <> "?" <> query
  end

  @doc "アーカイブ済みの表示。"
  attr :archived_at, :any, required: true

  def archived_badge(assigns) do
    ~H"""
    <span :if={@archived_at} class="badge badge-neutral">アーカイブ済み</span>
    """
  end

  @doc "ケース数 | バラ数 | 総バラ数 を 3 列で示すセル用の文字列。"
  def quantity_text(cases, pieces, units_per_case) do
    "#{cases} | #{pieces} | #{Calc.total_pieces(cases, pieces, units_per_case)}"
  end
end
