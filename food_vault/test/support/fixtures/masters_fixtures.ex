defmodule FoodVault.MastersFixtures do
  @moduledoc "`Makers` / `Warehouses` / `Items` のテスト用データ。公開 API 経由で作る。"

  alias FoodVault.{Items, Makers, Warehouses}

  import FoodVault.AccountsFixtures, only: [user_scope_fixture: 0]

  def unique_code(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  def maker_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        maker_code: unique_code("M"),
        maker_name: "テストメーカー"
      })

    {:ok, maker} = Makers.create_maker(user_scope_fixture(), attrs)
    maker
  end

  def warehouse_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        warehouse_code: unique_code("W"),
        warehouse_name: "テスト倉庫"
      })

    {:ok, warehouse} = Warehouses.create_warehouse(user_scope_fixture(), attrs)
    warehouse
  end

  @doc "商品を作る。`maker_id` を渡さなければメーカーも作る。"
  def item_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    attrs = Map.put_new_lazy(attrs, :maker_id, fn -> maker_fixture().id end)

    attrs =
      Map.merge(
        %{
          item_code: unique_code("I"),
          item_name: "テスト商品",
          units_per_case: 12,
          expiration_type: :best_before
        },
        attrs
      )

    {:ok, item} = Items.create_item(user_scope_fixture(), attrs)
    item
  end
end
