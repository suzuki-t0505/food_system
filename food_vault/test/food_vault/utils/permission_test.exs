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

    test "業務アクションのロール別の許可" do
      matrix = [
        # {action, admin, staff, viewer}
        {:manage_masters, true, false, false},
        {:receive_inventory, true, true, false},
        {:manage_shipment_order, true, true, false},
        {:adjust_inventory, true, false, false}
      ]

      for {action, admin, staff, viewer} <- matrix do
        assert Permission.can?(@admin, action) == admin
        assert Permission.can?(@staff, action) == staff
        assert Permission.can?(@viewer, action) == viewer
      end
    end

    test "未定義のアクションは拒否する" do
      refute Permission.can?(@admin, :no_such_action)
    end

    test "nil は拒否する" do
      refute Permission.can?(nil, :emergency_ship_order)
    end
  end

  describe "authorize/2" do
    test "画面のユーザーは can?/2 に従う" do
      assert Permission.authorize(@admin, :manage_masters) == :ok
      assert Permission.authorize(@staff, :manage_masters) == {:error, :forbidden}
      assert Permission.authorize(nil, :manage_masters) == {:error, :forbidden}
    end

    test "API の操作者は許可する" do
      assert Permission.authorize({:api, "staff@example.com"}, :adjust_inventory) == :ok
    end
  end
end
