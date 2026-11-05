defmodule FoodShip.Utils.CalcTest do
  use ExUnit.Case, async: true

  alias FoodShip.Utils.Calc

  test "total_piece_qty/2: 件数 × 商品数量" do
    assert Calc.total_piece_qty(3, 12) == 36
    assert Calc.total_piece_qty(1, 1) == 1
  end

  test "default_box_count/2: 件数 × 標準箱数" do
    assert Calc.default_box_count(3, 2) == 6
    assert Calc.default_box_count(5, 1) == 5
  end

  describe "min_expiration_date/2" do
    test "出荷予定日 + 最低残日数" do
      assert Calc.min_expiration_date(~D[2026-11-15], 30) == ~D[2026-12-15]
      assert Calc.min_expiration_date(~D[2026-11-15], 0) == ~D[2026-11-15]
    end

    test "ルールが無ければ制限なし(nil)" do
      assert Calc.min_expiration_date(~D[2026-11-15], nil) == nil
    end
  end
end
