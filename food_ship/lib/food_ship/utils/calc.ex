defmodule FoodShip.Utils.Calc do
  @moduledoc """
  伝票の数量・期限の計算。画面・Context の両方がここを呼び、計算式を各所に書かない。

  - 出庫総数量(バラ) = 件数 × 商品数量(`pieces_per_order`)
  - 箱数の初期値 = 件数 × 標準箱数(`boxes_per_order`)
  - 最低許容期限日 = 出荷予定日 + 最低残日数(ルールが無ければ制限なし = `nil`)
  """

  @doc "出庫総数量(バラ)。"
  def total_piece_qty(order_count, pieces_per_order)
      when is_integer(order_count) and is_integer(pieces_per_order),
      do: order_count * pieces_per_order

  @doc "箱数の初期値。"
  def default_box_count(order_count, boxes_per_order)
      when is_integer(order_count) and is_integer(boxes_per_order),
      do: order_count * boxes_per_order

  @doc "最低許容期限日。ルールが無い(`nil`)ときは制限なしで `nil`。"
  def min_expiration_date(%Date{}, nil), do: nil

  def min_expiration_date(%Date{} = ship_date, min_remaining_days)
      when is_integer(min_remaining_days),
      do: Date.add(ship_date, min_remaining_days)
end
