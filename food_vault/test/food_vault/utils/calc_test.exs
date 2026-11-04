defmodule FoodVault.Utils.CalcTest do
  use ExUnit.Case, async: true

  alias FoodVault.Utils.Calc

  describe "total_pieces/3" do
    test "ケース数 × 入数 + バラ数" do
      assert Calc.total_pieces(2, 3, 12) == 27
      assert Calc.total_pieces("2", "3", "12") == 27
    end

    test "空・不正値は 0 として扱う" do
      assert Calc.total_pieces("", nil, 12) == 0
      assert Calc.total_pieces("x", "5", 12) == 5
      assert Calc.total_pieces(-1, 2, 12) == 2
    end
  end

  describe "effective/2" do
    test "現在庫から引当済を引く" do
      lot = %{case_qty: 5, piece_qty: 7, allocated_case_qty: 2, allocated_piece_qty: 3}
      assert Calc.effective(lot, 10) == %{cases: 3, pieces: 4, total_pieces: 34}
    end

    test "item が読み込み済みなら入数を引数で渡さなくてよい" do
      lot = %{
        case_qty: 1,
        piece_qty: 0,
        allocated_case_qty: 0,
        allocated_piece_qty: 0,
        item: %{units_per_case: 6}
      }

      assert Calc.effective(lot).total_pieces == 6
      assert Calc.lot_total_pieces(lot) == 6
      assert Calc.allocated_total_pieces(lot) == 0
    end
  end

  describe "expiration_label/1" do
    test "9999-12-31 は期限なし" do
      assert Calc.expiration_label(~D[9999-12-31]) == "期限なし"
      assert Calc.expiration_label(Calc.no_expiration_date()) == "期限なし"
    end

    test "それ以外は ISO 形式" do
      assert Calc.expiration_label(~D[2026-11-15]) == "2026-11-15"
      assert Calc.expiration_label(nil) == ""
    end
  end

  describe "parse_int/1" do
    test "各種入力を非負整数にする" do
      assert Calc.parse_int(" 12 ") == 12
      assert Calc.parse_int("1.5") == 0
      assert Calc.parse_int("-3") == 0
      assert Calc.parse_int(nil) == 0
      assert Calc.parse_int(7) == 7
    end
  end
end
