defmodule FoodShip.ShippingSlips.AllocationResult do
  @moduledoc """
  在庫 API ①(出庫引当)の結果を、伝票へ反映する内容に変換する純粋関数。

  変換表は functional-design §6.3。引当合計の検証(`total_piece_qty` との一致)もここで行う。

    * `{:allocated, order_id, lots}` - 引当済み。`lots` は引当ロット(同じロットは合算)
    * `{:shortage, pieces}` - 在庫不足。`pieces` は不足バラ数の合計
    * `{:pending, allocation_error, extra}` - 引当待ちのまま。`extra` は `order_id`(在庫側に
      残っているオーダー。次の再引当で解除するため保存する)・`errors`(入力エラーの内容)
  """

  @doc "`Inventory.Client.allocate/1` の戻り値を、伝票への反映内容にする。"
  def from_response(slip, {:ok, order, _created_or_replayed}) do
    allocations = for line <- order.lines, allocation <- line.allocations, do: allocation
    pieces = allocations |> Enum.map(& &1.allocated_pieces) |> Enum.sum()
    cases = allocations |> Enum.map(& &1.allocated_cases) |> Enum.sum()

    if order.status == :allocated and cases == 0 and pieces == slip.total_piece_qty do
      {:allocated, order.order_id, lots(allocations)}
    else
      # 引当合計が一致しない(または引当済みでない)。在庫側にオーダーが残るので ID は保存する
      {:pending, :validation_failed, %{order_id: order.order_id}}
    end
  end

  def from_response(_slip, {:error, :insufficient_stock, shortages}) do
    {:shortage, shortages |> Enum.map(&(&1.shortage_pieces || 0)) |> Enum.sum()}
  end

  def from_response(_slip, {:error, :validation_failed, errors}),
    do: {:pending, :validation_failed, %{errors: errors}}

  def from_response(_slip, {:error, :idempotency_conflict, info}),
    do: {:pending, :idempotency_conflict, %{order_id: info[:order_id]}}

  def from_response(_slip, {:error, reason}), do: {:pending, error_for(reason), %{}}

  @doc """
  在庫 API のエラーを `allocation_error` の値にする。`:unauthorized`・`:not_found` は
  そのまま、想定外のもの(`:invalid_state` など)は再試行で直る可能性があるので `:connection`。
  """
  def error_for(reason) when reason in [:unauthorized, :not_found], do: reason
  def error_for(_reason), do: :connection

  @doc "在庫側のオーダーの引当を、伝票の引当ロット(同じロットは合算)にする。"
  def lots_from_order(order) do
    lots(for line <- order.lines, allocation <- line.allocations, do: allocation)
  end

  defp lots(allocations) do
    allocations
    |> Enum.filter(&(&1.allocated_pieces > 0))
    |> Enum.group_by(& &1.lot_id)
    |> Enum.map(fn {lot_id, [first | _] = group} ->
      %{
        inventory_lot_id: lot_id,
        expiration_date: first.expiration_date,
        allocated_pieces: group |> Enum.map(& &1.allocated_pieces) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{&1.expiration_date, &1.inventory_lot_id})
  end
end
