defmodule FoodVault.Utils.PermissionTest do
  use ExUnit.Case, async: true

  alias FoodVault.Utils.Permission

  @admin %{role: :admin}
  @staff %{role: :staff}
  @viewer %{role: :viewer}

  describe "role_at_least?/2" do
    test "admin は staff・viewer の操作を含む" do
      assert Permission.role_at_least?(@admin, :admin)
      assert Permission.role_at_least?(@admin, :staff)
      assert Permission.role_at_least?(@admin, :viewer)
    end

    test "staff は viewer の操作を含み、admin は含まない" do
      assert Permission.role_at_least?(@staff, :staff)
      assert Permission.role_at_least?(@staff, :viewer)
      refute Permission.role_at_least?(@staff, :admin)
    end

    test "viewer は viewer のみ" do
      assert Permission.role_at_least?(@viewer, :viewer)
      refute Permission.role_at_least?(@viewer, :staff)
      refute Permission.role_at_least?(@viewer, :admin)
    end

    test "nil・ロールなし・未知のロールは拒否する" do
      refute Permission.role_at_least?(nil, :viewer)
      refute Permission.role_at_least?(%{}, :viewer)
      refute Permission.role_at_least?(%{role: :guest}, :viewer)
    end
  end

  describe "can?/2" do
    test "緊急操作 (emergency_ship_order) は admin のみ" do
      assert Permission.can?(@admin, :emergency_ship_order)
      refute Permission.can?(@staff, :emergency_ship_order)
      refute Permission.can?(@viewer, :emergency_ship_order)
    end

    test "未定義のアクションは拒否する" do
      refute Permission.can?(@admin, :no_such_action)
    end

    test "nil は拒否する" do
      refute Permission.can?(nil, :emergency_ship_order)
    end
  end
end
