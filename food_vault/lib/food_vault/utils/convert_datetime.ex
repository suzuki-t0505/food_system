defmodule FoodVault.Utils.ConvertDatetime do
  @moduledoc """
  UTC と JST の変換。日時は UTC で保存し、表示直前にだけ JST へ変換する。

  日本は夏時間が無く、オフセットは常に +9 時間のため、タイムゾーンデータベースは使わない。
  期限日・入荷日などの `date` は業務日付なので、ここでは変換しない。
  """

  @jst_offset 9 * 3600

  @doc "現在の JST の日付。"
  def today_jst, do: DateTime.utc_now() |> to_jst() |> DateTime.to_date()

  @doc "UTC の日時を JST の `DateTime`(オフセットだけ加算した値)にする。"
  def to_jst(%DateTime{} = utc), do: DateTime.add(utc, @jst_offset)
  def to_jst(nil), do: nil

  @doc "表示用の JST 文字列(`YYYY-MM-DD HH:MM`)。"
  def format_jst(nil), do: ""

  def format_jst(%DateTime{} = utc) do
    utc |> to_jst() |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @doc "JST の日付 `date` の開始時刻(UTC)。"
  def beginning_of_day_utc(%Date{} = date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.add(-@jst_offset)
  end

  @doc "JST の日付 `date` の翌日の開始時刻(UTC)。範囲の上端(排他)に使う。"
  def end_of_day_utc(%Date{} = date), do: date |> Date.add(1) |> beginning_of_day_utc()
end
