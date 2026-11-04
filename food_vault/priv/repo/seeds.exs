# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FoodVault.Repo.insert!(%FoodVault.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# 初期管理者(開発: admin@example.com / admin-password-dev。環境変数で上書き可)。
# 有効な admin がいれば何もしない。
FoodVault.Release.run()

# 開発用のマスタ(メーカー 2・倉庫 2・商品 3。期限区分を 1 件ずつ)。コードで探して無ければ作る(冪等)。
# 入荷などの在庫データは作らない。
import Ecto.Query

alias FoodVault.Accounts.{Scope, User}
alias FoodVault.{Items, Makers, Repo, Warehouses}
alias FoodVault.Items.Item
alias FoodVault.Makers.Maker
alias FoodVault.Warehouses.Warehouse

scope =
  User
  |> where([u], u.role == :admin and is_nil(u.archived_at))
  |> order_by([u], asc: u.inserted_at)
  |> limit(1)
  |> Repo.one!()
  |> Scope.for_user()

ensure = fn schema, field, code, create ->
  Repo.get_by(schema, [{field, code}]) || elem(create.(), 1)
end

maker_a =
  ensure.(Maker, :maker_code, "M01", fn ->
    Makers.create_maker(scope, %{maker_code: "M01", maker_name: "メーカーA"})
  end)

maker_b =
  ensure.(Maker, :maker_code, "M02", fn ->
    Makers.create_maker(scope, %{maker_code: "M02", maker_name: "メーカーB"})
  end)

for {code, name} <- [{"W01", "第1倉庫"}, {"W02", "第2倉庫"}] do
  ensure.(Warehouse, :warehouse_code, code, fn ->
    Warehouses.create_warehouse(scope, %{warehouse_code: code, warehouse_name: name})
  end)
end

for {code, name, maker, units, type} <- [
      {"I001", "缶詰(賞味期限)", maker_a, 24, :best_before},
      {"I002", "惣菜(消費期限)", maker_a, 12, :consumption},
      {"I003", "調味料(期限なし)", maker_b, 6, :none}
    ] do
  ensure.(Item, :item_code, code, fn ->
    Items.create_item(scope, %{
      item_code: code,
      item_name: name,
      maker_id: maker.id,
      units_per_case: units,
      expiration_type: type
    })
  end)
end
