defmodule FoodVault.WarehousesTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.Repo
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
      insert_lot!(warehouse, item_fixture(), case_qty: 1)

      assert {:error, :has_stock} = Warehouses.archive_warehouse(user_scope_fixture(), warehouse)
    end

    test "在庫 0 のロットだけならアーカイブできる" do
      warehouse = warehouse_fixture()
      insert_lot!(warehouse, item_fixture(), case_qty: 0, piece_qty: 0)

      assert {:ok, _} = Warehouses.archive_warehouse(user_scope_fixture(), warehouse)
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Warehouses.archive_warehouse(scope, warehouse_fixture())
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

  # 入荷(単位 B)より前に作るため、ロットを直接作る
  defp insert_lot!(warehouse, item, qty) do
    Repo.insert!(%InventoryLot{
      warehouse_id: warehouse.id,
      item_id: item.id,
      expiration_date: ~D[2027-01-01],
      received_date: ~D[2026-11-01],
      case_qty: Keyword.get(qty, :case_qty, 0),
      piece_qty: Keyword.get(qty, :piece_qty, 0)
    })
  end
end
