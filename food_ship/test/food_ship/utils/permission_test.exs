defmodule FoodShip.Utils.PermissionTest do
  use ExUnit.Case, async: true

  alias FoodShip.Utils.Permission

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
    test "ユーザー管理 (manage_users) は admin のみ" do
      assert Permission.can?(@admin, :manage_users)
      refute Permission.can?(@staff, :manage_users)
      refute Permission.can?(@viewer, :manage_users)
    end

    test "自分のパスワード変更 (change_own_password) は全ロール" do
      assert Permission.can?(@admin, :change_own_password)
      assert Permission.can?(@staff, :change_own_password)
      assert Permission.can?(@viewer, :change_own_password)
    end

    test "未定義のアクションは拒否する" do
      refute Permission.can?(@admin, :no_such_action)
    end

    test "nil は拒否する" do
      refute Permission.can?(nil, :no_such_action)
    end
  end
end
