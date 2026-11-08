defmodule FoodShipWeb.ReportHTML do
  @moduledoc """
  帳票(PDF)の HTML。A4 縦・日本語フォント(Noto Sans JP)。

  **外部リソースを読み込まない**(画像・フォント・スクリプト・CSS の外部 URL を書かない)。
  差し込む値は HEEx のエスケープのみ。日本語フォントはイメージにインストールした
  `fonts-noto-cjk` を名前で指定する。集計はコントローラ(`FoodShip.TotalPicks`)が算出し、
  テンプレートに計算式を書かない。日時は JST。

    * `total_pick_document/1` - トータルピック表(ピック表 → 仕分け表)
    * `work_order_document/1` - 作業指示書(伝票 1 枚)
    * `bundle_document/1` - ピック表 → 仕分け表 → 作業指示書(`slip_no` 昇順)
  """

  use FoodShipWeb, :html

  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.ConvertDatetime

  embed_templates "report_html/*"

  @style """
  @page { size: A4 portrait; margin: 12mm; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body { font-family: "Noto Sans JP", "Noto Sans CJK JP", sans-serif; font-size: 10pt; color: #000; }
  h1 { font-size: 16pt; margin: 0 0 6pt; }
  h2 { font-size: 12pt; margin: 10pt 0 4pt; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 8pt; }
  th, td { border: 0.5pt solid #000; padding: 3pt 4pt; vertical-align: top; }
  th { background: #eee; font-weight: bold; text-align: left; }
  thead { display: table-header-group; }
  tr { break-inside: avoid; }
  .num { text-align: right; white-space: nowrap; }
  .meta th { width: 22%; }
  .check { width: 14mm; }
  .total td { font-weight: bold; background: #f6f6f6; }
  .write-in { height: 14mm; }
  .page + .page { break-before: page; }
  .small { font-size: 8.5pt; }
  """

  @doc "共通の文書枠(`<style>` だけを持つ。外部リソースなし)。"
  slot :inner_block, required: true
  attr :title, :string, required: true

  def document(assigns) do
    assigns = assign(assigns, :style, @style)

    ~H"""
    <!doctype html>
    <html lang="ja">
      <head>
        <meta charset="utf-8" />
        <title>{@title}</title>
        <style>
          <%= Phoenix.HTML.raw(@style) %>
        </style>
      </head>
      <body>
        {render_slot(@inner_block)}
      </body>
    </html>
    """
  end

  @doc "トータルピック表の文書。`summary` は `FoodShip.TotalPicks.summarize/1` の結果。"
  attr :pick, :map, required: true
  attr :summary, :map, required: true

  def total_pick_document(assigns) do
    ~H"""
    <.document title={TotalPick.pick_no_label(@pick)}>
      <.pick_sheet pick={@pick} summary={@summary} />
    </.document>
    """
  end

  @doc "作業指示書の文書（伝票 1 枚）。"
  attr :slip, :map, required: true
  attr :pick, :map, default: nil

  def work_order_document(assigns) do
    ~H"""
    <.document title={ShippingSlip.slip_no_label(@slip)}>
      <.work_order_sheet slip={@slip} pick={@pick} />
    </.document>
    """
  end

  @doc "ピック表 → 仕分け表 → 所属伝票の作業指示書（`slip_no` 昇順）。"
  attr :pick, :map, required: true
  attr :summary, :map, required: true
  attr :slips, :list, required: true

  def bundle_document(assigns) do
    ~H"""
    <.document title={TotalPick.pick_no_label(@pick)}>
      <.pick_sheet pick={@pick} summary={@summary} />
      <.work_order_sheet :for={slip <- @slips} slip={slip} pick={@pick} />
    </.document>
    """
  end

  @doc "ピック番号の表示（`TP-000045`）。"
  def pick_no(%TotalPick{} = pick), do: TotalPick.pick_no_label(pick)

  @doc "伝票番号の表示（`S-000123`）。"
  def slip_no(%ShippingSlip{} = slip), do: ShippingSlip.slip_no_label(slip)

  @doc "伝票番号（整数）の表示。"
  def slip_no_text(slip_no), do: ShippingSlip.format_slip_no(slip_no)

  @doc "期限日の表示（期限なしは「期限なし」）。"
  def expiration(%Date{} = date), do: SlipAllocatedLot.expiration_label(date)

  @doc "日時（UTC）を JST で表示する。"
  def datetime(%DateTime{} = utc), do: ConvertDatetime.format_jst(utc)
end
