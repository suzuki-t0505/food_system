defmodule FoodVault.ShipmentOrders.AllocationPlanTest do
  use ExUnit.Case, async: true

  alias FoodVault.ShipmentOrders.AllocationPlan

  # 入数 12 のロット。有効数量 = 現在庫 - 引当済
  defp lot(id, cases, pieces, alloc_cases \\ 0, alloc_pieces \\ 0) do
    %{
      id: id,
      case_qty: cases,
      piece_qty: pieces,
      allocated_case_qty: alloc_cases,
      allocated_piece_qty: alloc_pieces
    }
  end

  describe "plan_line/4 ケース要求" do
    test "先頭のロットから引き当て、足りなければ次のロットへ進む" do
      lots = [lot("a", 2, 0), lot("b", 5, 0)]

      assert {:ok, %{allocations: allocations, breaks: []}} =
               AllocationPlan.plan_line(lots, 12, 4, 0)

      assert allocations == [
               %{lot_id: "a", cases: 2, pieces: 0},
               %{lot_id: "b", cases: 2, pieces: 0}
             ]
    end

    test "引当済みのケースは対象にしない" do
      lots = [lot("a", 3, 0, 2, 0), lot("b", 1, 0)]

      assert {:ok, %{allocations: [%{lot_id: "a", cases: 1}, %{lot_id: "b", cases: 1}]}} =
               AllocationPlan.plan_line(lots, 12, 2, 0)
    end

    test "足りなければ不足ケース数を返す" do
      assert {:shortage, %{cases: 3, pieces: 0}} =
               AllocationPlan.plan_line([lot("a", 2, 0)], 12, 5, 0)
    end
  end

  describe "plan_line/4 バラ要求" do
    test "バラ在庫から引き当てる(荷崩ししない)" do
      assert {:ok, %{allocations: [%{lot_id: "a", cases: 0, pieces: 5}], breaks: []}} =
               AllocationPlan.plan_line([lot("a", 3, 8)], 12, 0, 5)
    end

    test "バラが足りなければ同一ロット内で荷崩しする(余りはバラ在庫に残る)" do
      assert {:ok, %{allocations: allocations, breaks: breaks}} =
               AllocationPlan.plan_line([lot("a", 3, 2)], 12, 0, 5)

      # バラ 2 + 荷崩し 1 ケース(12 個)のうち 3 個
      assert allocations == [%{lot_id: "a", cases: 0, pieces: 5}]
      assert breaks == [%{lot_id: "a", cases: 1, pieces: 12}]
    end

    test "複数ケースの荷崩しは k を一度に求めて 1 行に合算する" do
      # 30 個要求、入数 12 → ceil(30/12) = 3 ケース開封
      assert {:ok, %{allocations: [%{pieces: 30}], breaks: [%{cases: 3, pieces: 36}]}} =
               AllocationPlan.plan_line([lot("a", 5, 0)], 12, 0, 30)
    end

    test "荷崩しは有効ケース数が上限(ケース要求で引き当てた分は崩さない)" do
      # 3 ケースのうち 2 ケースをケース要求で引当 → 残り 1 ケースだけ荷崩し可能
      assert {:ok, %{allocations: [%{cases: 2, pieces: 12}], breaks: [%{cases: 1, pieces: 12}]}} =
               AllocationPlan.plan_line([lot("a", 3, 0)], 12, 2, 12)

      assert {:shortage, %{cases: 0, pieces: 1}} =
               AllocationPlan.plan_line([lot("a", 3, 0)], 12, 2, 13)
    end

    test "先頭のロットを使い切ってから次のロットで荷崩しする" do
      lots = [lot("a", 0, 4), lot("b", 2, 1)]

      assert {:ok, %{allocations: allocations, breaks: breaks}} =
               AllocationPlan.plan_line(lots, 12, 0, 10)

      assert allocations == [
               %{lot_id: "a", cases: 0, pieces: 4},
               %{lot_id: "b", cases: 0, pieces: 6}
             ]

      assert breaks == [%{lot_id: "b", cases: 1, pieces: 12}]
    end

    test "全ロットを走査しても足りなければ不足バラ数を返す" do
      lots = [lot("a", 1, 3), lot("b", 0, 2)]

      # 総バラ 12 + 3 + 2 = 17。20 個要求なら 3 個不足
      assert {:shortage, %{cases: 0, pieces: 3}} = AllocationPlan.plan_line(lots, 12, 0, 20)
    end

    test "引当済みのバラは対象にしない" do
      assert {:shortage, %{pieces: 3}} =
               AllocationPlan.plan_line([lot("a", 0, 5, 0, 3)], 12, 0, 5)
    end
  end

  describe "plan_line/4 ケースとバラの併用" do
    test "ケース要求とバラ要求を同じロットから引き当てると 1 行に合算する" do
      assert {:ok, %{allocations: [%{lot_id: "a", cases: 1, pieces: 3}], breaks: [%{cases: 1}]}} =
               AllocationPlan.plan_line([lot("a", 3, 0)], 12, 1, 3)
    end

    test "ケースもバラも不足なら両方の不足数を返す(ケース要求で使い切ったケースは荷崩ししない)" do
      assert {:shortage, %{cases: 1, pieces: 14}} =
               AllocationPlan.plan_line([lot("a", 1, 0)], 12, 2, 14)
    end
  end

  test "ロットが無ければ全量が不足" do
    assert {:shortage, %{cases: 2, pieces: 5}} = AllocationPlan.plan_line([], 12, 2, 5)
  end
end
