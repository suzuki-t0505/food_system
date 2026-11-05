defmodule FoodShip.MastersFixtures do
  @moduledoc "`Clients` / `ShippingItems` / `ExpirationRules` のテスト用データ。公開 API 経由で作る。"

  alias FoodShip.{Clients, ExpirationRules, ShippingItems}

  import FoodShip.AccountsFixtures, only: [user_scope_fixture: 0]

  def unique_code(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  def client_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        client_code: unique_code("C"),
        client_name: "テスト発注元"
      })

    {:ok, client} = Clients.create_client(user_scope_fixture(), attrs)
    client
  end

  @doc """
  発送商品を作る。在庫側の ID(`inventory_item_id`・`inventory_maker_id`)は新しい ULID にする。
  既定は 1 件 = 標準 2 箱・バラ 12 個。
  """
  def shipping_item_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        inventory_item_id: Ecto.ULID.generate(),
        item_code: unique_code("I"),
        inventory_maker_id: Ecto.ULID.generate(),
        maker_name: "テストメーカー",
        item_name: "テスト商品",
        boxes_per_order: 2,
        pieces_per_order: 12
      })

    {:ok, item} = ShippingItems.create_shipping_item(user_scope_fixture(), attrs)
    item
  end

  @doc "出荷期限ルールを作る。`client_id`・`shipping_item_id` を渡さなければ作る。"
  def expiration_rule_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    attrs = Map.put_new_lazy(attrs, :client_id, fn -> client_fixture().id end)
    attrs = Map.put_new_lazy(attrs, :shipping_item_id, fn -> shipping_item_fixture().id end)
    attrs = Map.put_new(attrs, :min_remaining_days, 30)

    {:ok, rule} = ExpirationRules.create_expiration_rule(user_scope_fixture(), attrs)
    rule
  end
end
