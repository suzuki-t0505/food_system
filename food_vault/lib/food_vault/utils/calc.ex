defmodule FoodVault.Utils.Calc do
  @moduledoc """
  数量・期限の計算と表示用の整形。状態を持たない純関数のみ。

  総バラ数 = ケース数 × 入数 + バラ数。画面の入力欄は空文字や不正値が来るため、
  `parse_int/1` で非負整数に丸めてから計算する。
  """

  @no_expiration ~D[9999-12-31]

  @doc "期限なし(期限区分 `none`)の商品に保存する期限日。"
  def no_expiration_date, do: @no_expiration

  @doc "総バラ数。"
  def total_pieces(cases, pieces, units_per_case) do
    parse_int(cases) * parse_int(units_per_case) + parse_int(pieces)
  end

  @doc """
  ロットの有効在庫(現在庫 − 引当済)。

  `%{cases: 有効ケース数, pieces: 有効バラ数, total_pieces: 有効総バラ数}` を返す。
  `units_per_case` はロットの `item` が読み込まれていなければ引数で渡す。
  """
  def effective(lot, units_per_case \\ nil) do
    upc = units_per_case || lot.item.units_per_case
    cases = lot.case_qty - lot.allocated_case_qty
    pieces = lot.piece_qty - lot.allocated_piece_qty

    %{cases: cases, pieces: pieces, total_pieces: cases * upc + pieces}
  end

  @doc "ロットの現在庫の総バラ数。"
  def lot_total_pieces(lot, units_per_case \\ nil) do
    total_pieces(lot.case_qty, lot.piece_qty, units_per_case || lot.item.units_per_case)
  end

  @doc "ロットの引当済の総バラ数。"
  def allocated_total_pieces(lot, units_per_case \\ nil) do
    total_pieces(
      lot.allocated_case_qty,
      lot.allocated_piece_qty,
      units_per_case || lot.item.units_per_case
    )
  end

  @doc "期限日の表示。`9999-12-31` は「期限なし」。"
  def expiration_label(%Date{} = date) do
    if Date.compare(date, @no_expiration) == :eq, do: "期限なし", else: Date.to_iso8601(date)
  end

  def expiration_label(_), do: ""

  @doc "入力値を非負整数に変換する。空・nil・不正値・負数は 0。"
  def parse_int(value) when is_integer(value), do: max(value, 0)

  def parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> max(int, 0)
      _ -> 0
    end
  end

  def parse_int(_), do: 0
end
