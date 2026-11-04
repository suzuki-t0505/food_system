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
