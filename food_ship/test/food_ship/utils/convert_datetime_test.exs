defmodule FoodShip.Utils.ConvertDatetimeTest do
  use ExUnit.Case, async: true

  alias FoodShip.Utils.ConvertDatetime

  test "to_jst/1: UTC に 9 時間を足す(日付をまたぐ)" do
    assert ConvertDatetime.to_jst(~U[2026-11-15 20:30:00Z]) == ~U[2026-11-16 05:30:00Z]
    assert ConvertDatetime.to_jst(nil) == nil
  end

  test "format_jst/1: YYYY-MM-DD HH:MM" do
    assert ConvertDatetime.format_jst(~U[2026-11-15 20:30:45Z]) == "2026-11-16 05:30"
    assert ConvertDatetime.format_jst(nil) == ""
  end

  test "today_jst/0: Date を返す" do
    assert %Date{} = ConvertDatetime.today_jst()
  end
end
