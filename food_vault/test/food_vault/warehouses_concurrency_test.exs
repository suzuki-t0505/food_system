defmodule FoodVault.WarehousesConcurrencyTest do
  use FoodVault.ConcurrencyCase, async: false

  import Ecto.Query, only: [from: 2]
  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Repo, Warehouses}
  alias FoodVault.Warehouses.Warehouse

  test "別々の倉庫を同時にデフォルトにしても、デフォルトは 1 件だけ" do
    scope = user_scope_fixture()
    warehouses = for _ <- 1..4, do: warehouse_fixture()

    results =
      concurrently(4, fn n ->
        Warehouses.set_default_warehouse(scope, Enum.at(warehouses, n - 1))
      end)

    # 後から来た切り替えは、部分ユニークインデックスの違反としてエラーになってよい
    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert [%Warehouse{}] = Repo.all(from w in Warehouse, where: w.is_default)
  end
end
