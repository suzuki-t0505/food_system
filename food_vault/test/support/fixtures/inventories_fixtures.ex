defmodule FoodVault.InventoriesFixtures do
  @moduledoc "`Inventories` のテスト用データ。入荷の公開 API 経由で作る。"

  alias FoodVault.Inventories

  import FoodVault.AccountsFixtures, only: [admin_fixture: 0]
  import FoodVault.MastersFixtures, only: [item_fixture: 0, warehouse_fixture: 0]

  @doc """
  入荷してロットを返す。`warehouse_id`・`item_id` を渡さなければ作る。
  既定は 1 ケース、期限日 2027-01-01、入荷日 2026-11-01。
  """
  def lot_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {actor, attrs} = Map.pop_lazy(attrs, :actor, &admin_fixture/0)

    attrs =
      attrs
      |> Map.put_new_lazy(:warehouse_id, fn -> warehouse_fixture().id end)
      |> Map.put_new_lazy(:item_id, fn -> item_fixture().id end)

    attrs =
      Map.merge(
        %{
          expiration_date: ~D[2027-01-01],
          received_date: ~D[2026-11-01],
          case_qty: 1,
          piece_qty: 0
        },
        attrs
      )

    {:ok, %{lot: lot}} = Inventories.receive_inventory(actor, attrs)
    lot
  end
end
