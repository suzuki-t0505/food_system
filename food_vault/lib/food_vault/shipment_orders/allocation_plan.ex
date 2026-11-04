defmodule FoodVault.ShipmentOrders.AllocationPlan do
  @moduledoc """
  明細 1 行ぶんの引当計画を立てる純粋関数(DB に触らない)。

  呼び出し側が**先出し順**(期限日 → 入荷日 → ロット ID)に並べ、ロックしたロットを渡す。
  ロットは `%{id, case_qty, piece_qty, allocated_case_qty, allocated_piece_qty}` を持つ。

  ## 手順

    1. ケース要求分(`req_cases`): 各ロットの有効ケース数から、要求を満たすまで引き当てる
    2. バラ要求分(`req_pieces`): ロットを上から走査し、
       ① 有効バラ数から引き当てる
       ② まだ足りず有効ケースがあれば、同一ロット内で荷崩しする。
          開封ケース数は `k = min(有効ケース数, ceil(残り ÷ 入数))` を一度に求める
       ③ それでも足りなければ次のロットへ

  荷崩しで余ったバラはそのロットのバラ在庫として残る。ステップ 1 で引き当てたケースは
  有効ケース数から引くので、荷崩しの対象にならない。
  """

  @type result ::
          {:ok, %{allocations: [map()], breaks: [map()]}}
          | {:shortage, %{cases: non_neg_integer(), pieces: non_neg_integer()}}

  @doc """
  戻り値:

    * `{:ok, %{allocations: [%{lot_id, cases, pieces}], breaks: [%{lot_id, cases, pieces}]}}`
      - `breaks` は荷崩し(`cases` を開封し、`pieces = cases × 入数` のバラが増える)
    * `{:shortage, %{cases: 不足ケース数, pieces: 不足バラ数}}`
  """
  @spec plan_line([map()], pos_integer(), non_neg_integer(), non_neg_integer()) :: result()
  def plan_line(lots, units_per_case, req_cases, req_pieces) do
    states =
      Enum.map(lots, fn lot ->
        %{
          lot_id: lot.id,
          eff_cases: lot.case_qty - lot.allocated_case_qty,
          eff_pieces: lot.piece_qty - lot.allocated_piece_qty,
          alloc_cases: 0,
          alloc_pieces: 0,
          break_cases: 0
        }
      end)

    {states, short_cases} = take_cases(states, req_cases)
    {states, short_pieces} = take_pieces(states, req_pieces, units_per_case)

    if short_cases == 0 and short_pieces == 0 do
      {:ok, build_result(states, units_per_case)}
    else
      {:shortage, %{cases: short_cases, pieces: short_pieces}}
    end
  end

  # ステップ 1: ケース
  defp take_cases(states, required) do
    {states, remaining} =
      Enum.map_reduce(states, required, fn state, remaining ->
        take = min(state.eff_cases, remaining)

        {%{state | eff_cases: state.eff_cases - take, alloc_cases: state.alloc_cases + take},
         remaining - take}
      end)

    {states, remaining}
  end

  # ステップ 2: バラ(足りなければ同一ロット内で荷崩し)
  defp take_pieces(states, required, units_per_case) do
    Enum.map_reduce(states, required, fn state, remaining ->
      state |> take_loose_pieces(remaining) |> break_cases_for(units_per_case)
    end)
  end

  defp take_loose_pieces(state, remaining) do
    take = min(state.eff_pieces, remaining)

    {%{state | eff_pieces: state.eff_pieces - take, alloc_pieces: state.alloc_pieces + take},
     remaining - take}
  end

  defp break_cases_for({state, remaining}, _units_per_case) when remaining == 0, do: {state, 0}

  defp break_cases_for({%{eff_cases: 0} = state, remaining}, _units_per_case),
    do: {state, remaining}

  defp break_cases_for({state, remaining}, units_per_case) do
    k = min(state.eff_cases, ceil_div(remaining, units_per_case))
    opened = k * units_per_case
    take = min(opened, remaining)

    {%{
       state
       | eff_cases: state.eff_cases - k,
         break_cases: state.break_cases + k,
         eff_pieces: state.eff_pieces + opened - take,
         alloc_pieces: state.alloc_pieces + take
     }, remaining - take}
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp build_result(states, units_per_case) do
    allocations =
      for s <- states, s.alloc_cases + s.alloc_pieces > 0 do
        %{lot_id: s.lot_id, cases: s.alloc_cases, pieces: s.alloc_pieces}
      end

    breaks =
      for s <- states, s.break_cases > 0 do
        %{lot_id: s.lot_id, cases: s.break_cases, pieces: s.break_cases * units_per_case}
      end

    %{allocations: allocations, breaks: breaks}
  end
end
