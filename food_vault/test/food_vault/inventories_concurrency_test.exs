defmodule FoodVault.InventoriesConcurrencyTest do
  use FoodVault.ConcurrencyCase, async: false

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Inventories, Items, Repo}
  alias FoodVault.Inventories.InventoryLot

  test "同じロットへの同時入荷でも加算が失われない" do
    warehouse = warehouse_fixture()
    item = item_fixture()
    staff = user_fixture(%{role: :staff})

    attrs = %{
      warehouse_id: warehouse.id,
      item_id: item.id,
      expiration_date: ~D[2027-01-01],
      received_date: ~D[2026-11-01],
      case_qty: 1,
      piece_qty: 2
    }

    results = concurrently(5, fn _ -> Inventories.receive_inventory(staff, attrs) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [lot] = Repo.all(InventoryLot)
    assert lot.case_qty == 5
    assert lot.piece_qty == 10
  end

  test "入荷とマスタ更新が同時に走っても、ロットがある商品の入数は変わらない" do
    warehouse = warehouse_fixture()
    item = item_fixture(%{units_per_case: 12})
    staff = user_fixture(%{role: :staff})
    scope = user_scope_fixture()

    receive_attrs = %{
      warehouse_id: warehouse.id,
      item_id: item.id,
      expiration_date: ~D[2027-01-01],
      received_date: ~D[2026-11-01],
      case_qty: 1
    }

    results =
      concurrently(2, fn
        1 -> {:receive, Inventories.receive_inventory(staff, receive_attrs)}
        2 -> {:update, Items.update_item(scope, item, %{units_per_case: 24})}
      end)

    {:receive, {:ok, _}} = List.keyfind(results, :receive, 0)
    {:update, update_result} = List.keyfind(results, :update, 0)
    reloaded = Items.get_item!(item.id)

    # 入荷が先ならロットがあるので更新は拒否される。更新が先なら入数 24 でロットができる。
    # どちらでも「ロットがあるのに入数が変わった」状態(入荷時点と異なる入数)にはならない
    case update_result do
      {:error, :lots_exist} -> assert reloaded.units_per_case == 12
      {:ok, _} -> assert reloaded.units_per_case == 24
    end
  end
end
