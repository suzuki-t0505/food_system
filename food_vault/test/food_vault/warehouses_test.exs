defmodule FoodVault.WarehousesTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.Warehouses
  alias FoodVault.Warehouses.Warehouse

  describe "create_warehouse/2" do
    test "admin は登録でき、コードの重複は拒否する" do
      scope = user_scope_fixture()

      assert {:ok, %Warehouse{warehouse_code: "W01"}} =
               Warehouses.create_warehouse(scope, %{warehouse_code: "W01", warehouse_name: "第1"})

      assert {:error, changeset} =
               Warehouses.create_warehouse(scope, %{warehouse_code: "W01", warehouse_name: "第2"})

      assert %{warehouse_code: ["has already been taken"]} = errors_on(changeset)
    end

    test "viewer は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :viewer, must_change_password: false}))

      assert {:error, :forbidden} =
               Warehouses.create_warehouse(scope, %{warehouse_code: "W", warehouse_name: "W"})
    end
  end

  describe "update_warehouse/3" do
    test "名称を更新できる" do
      assert {:ok, %Warehouse{warehouse_name: "新倉庫"}} =
               Warehouses.update_warehouse(user_scope_fixture(), warehouse_fixture(), %{
                 warehouse_name: "新倉庫"
               })
    end
  end

  describe "archive_warehouse/2 と restore_warehouse/2" do
    test "在庫が無ければアーカイブでき、選択肢から消え、復帰できる" do
      warehouse = warehouse_fixture()
      scope = user_scope_fixture()

      assert {:ok, archived} = Warehouses.archive_warehouse(scope, warehouse)
      assert Warehouse.archived?(archived)
      refute Enum.any?(Warehouses.all_warehouses(), &(&1.id == warehouse.id))

      assert {:ok, restored} = Warehouses.restore_warehouse(scope, archived)
      refute Warehouse.archived?(restored)
    end

    test "在庫があれば拒否する" do
      warehouse = warehouse_fixture()
      lot_fixture(%{warehouse_id: warehouse.id, case_qty: 1})

      assert {:error, :has_stock} = Warehouses.archive_warehouse(user_scope_fixture(), warehouse)
    end

    test "在庫 0 のロットだけならアーカイブできる" do
      warehouse = warehouse_fixture()
      empty_lot!(warehouse)

      assert {:ok, _} = Warehouses.archive_warehouse(user_scope_fixture(), warehouse)
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Warehouses.archive_warehouse(scope, warehouse_fixture())
    end

    test "デフォルト倉庫は拒否し、別の倉庫をデフォルトにすればアーカイブできる" do
      scope = user_scope_fixture()
      first = warehouse_fixture()
      second = warehouse_fixture()
      {:ok, first} = Warehouses.set_default_warehouse(scope, first)

      assert {:error, :default_warehouse} = Warehouses.archive_warehouse(scope, first)

      {:ok, _} = Warehouses.set_default_warehouse(scope, second)
      first = Warehouses.get_warehouse!(first.id)
      assert {:ok, archived} = Warehouses.archive_warehouse(scope, first)
      assert Warehouse.archived?(archived)
    end
  end

  describe "set_default_warehouse/2 と get_default_warehouse/0" do
    test "未設定なら nil" do
      assert is_nil(Warehouses.get_default_warehouse())
    end

    test "デフォルトにでき、別の倉庫に切り替えると前のデフォルトは外れる" do
      scope = user_scope_fixture()
      first = warehouse_fixture()
      second = warehouse_fixture()

      assert {:ok, %Warehouse{is_default: true}} = Warehouses.set_default_warehouse(scope, first)
      assert Warehouses.get_default_warehouse().id == first.id

      assert {:ok, %Warehouse{is_default: true}} = Warehouses.set_default_warehouse(scope, second)
      assert Warehouses.get_default_warehouse().id == second.id
      refute Warehouses.get_warehouse!(first.id).is_default
    end

    test "すでにデフォルトなら成功し、そのまま" do
      scope = user_scope_fixture()
      warehouse = warehouse_fixture()
      {:ok, _} = Warehouses.set_default_warehouse(scope, warehouse)

      assert {:ok, %Warehouse{is_default: true}} =
               Warehouses.set_default_warehouse(scope, warehouse)

      assert Warehouses.get_default_warehouse().id == warehouse.id
    end

    test "アーカイブ済みの倉庫はデフォルトにできない" do
      scope = user_scope_fixture()
      warehouse = warehouse_fixture()
      {:ok, archived} = Warehouses.archive_warehouse(scope, warehouse)

      assert {:error, :archived} = Warehouses.set_default_warehouse(scope, archived)
      assert is_nil(Warehouses.get_default_warehouse())
    end

    test "登録・更新ではデフォルトを変えられない" do
      scope = user_scope_fixture()

      assert {:ok, created} =
               Warehouses.create_warehouse(scope, %{
                 warehouse_code: "DEF-1",
                 warehouse_name: "X",
                 is_default: true
               })

      refute created.is_default

      assert {:ok, updated} = Warehouses.update_warehouse(scope, created, %{is_default: true})
      refute updated.is_default
    end

    test "viewer・staff は拒否する" do
      warehouse = warehouse_fixture()

      for role <- [:viewer, :staff] do
        scope = user_scope_fixture(user_fixture(%{role: role, must_change_password: false}))
        assert {:error, :forbidden} = Warehouses.set_default_warehouse(scope, warehouse)
      end

      assert is_nil(Warehouses.get_default_warehouse())
    end

    test "部分ユニークインデックスで、デフォルトは 2 件にならない" do
      first = warehouse_fixture()
      second = warehouse_fixture()
      {:ok, _} = Warehouses.set_default_warehouse(user_scope_fixture(), first)

      assert {:error, changeset} =
               second |> Warehouse.default_changeset() |> FoodVault.Repo.update()

      assert %{is_default: [_]} = errors_on(changeset)
    end
  end

  describe "lock_active_warehouse_for_share/1" do
    test "有効な倉庫は返し、アーカイブ済みは nil" do
      warehouse = warehouse_fixture()
      assert %Warehouse{} = Warehouses.lock_active_warehouse_for_share(warehouse.id)

      {:ok, _} = Warehouses.archive_warehouse(user_scope_fixture(), warehouse)
      assert is_nil(Warehouses.lock_active_warehouse_for_share(warehouse.id))
    end
  end

  # 入荷した後に全数を出庫した状態(在庫 0 のロット)を作る
  defp empty_lot!(warehouse) do
    lot = lot_fixture(%{warehouse_id: warehouse.id, case_qty: 1})
    lot |> Ecto.Changeset.change(case_qty: 0) |> FoodVault.Repo.update!()
  end
end
