defmodule FoodShip.ShippingSlips.Bulk do
  @moduledoc """
  伝票を 1 件ずつ順に処理する(CSV 取込後の引当・一括再引当・一括梱包完了で共通)。

  1 件の処理は `FoodShip.ShippingSlips` の既存の関数(`allocate_shipping_slip/2`・
  `pack_shipping_slip/2`)に任せる。ここは「与えられた順に呼び、1 件ごとに結果を通知する」だけで、
  並び順は呼び出し側が決める。画面は `Task` の中でこの関数を呼び、`notify` で `handle_info` へ
  進捗を送る。

  1 件の例外(`raise`・`exit`・`throw`)は `{:error, :unexpected}` として扱い、残りの伝票は続ける。
  途中でプロセスごと止まった場合、処理されなかった伝票は `pending` / `allocated` のまま残るので、
  一括再引当・一括梱包完了をやり直せる。
  """

  require Logger

  alias FoodShip.ShippingSlips.ShippingSlip

  @type result :: {:ok, %ShippingSlip{}} | {:ok, %ShippingSlip{}, map()} | {:error, term()}

  @doc """
  `slips` を与えられた順に `fun.(scope, slip)` で処理し、1 件ごとに
  `notify.(index, total, slip, result)` を呼ぶ(`index` は 1 始まり)。全件の処理後に `:ok`。
  """
  @spec run(
          term(),
          [%ShippingSlip{}],
          (term(), %ShippingSlip{} -> result()),
          (pos_integer(), pos_integer(), %ShippingSlip{}, result() -> any())
        ) :: :ok
  def run(scope, slips, fun, notify) when is_function(fun, 2) and is_function(notify, 4) do
    total = length(slips)

    slips
    |> Enum.with_index(1)
    |> Enum.each(fn {slip, index} ->
      notify.(index, total, slip, safely(fun, scope, slip))
    end)
  end

  defp safely(fun, scope, slip) do
    fun.(scope, slip)
  rescue
    exception ->
      Logger.error("一括処理で予期しない例外: #{Exception.message(exception)}")
      {:error, :unexpected}
  catch
    kind, reason ->
      Logger.error("一括処理で予期しない終了: #{inspect({kind, reason})}")
      {:error, :unexpected}
  end
end
