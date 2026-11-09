defmodule FoodVault.Repo.Migrations.AddIsDefaultToWarehouses do
  use Ecto.Migration

  def change do
    alter table(:warehouses) do
      add :is_default, :boolean, null: false, default: false
    end

    # デフォルト倉庫は 0 件または 1 件
    create unique_index(:warehouses, [:is_default],
             where: "is_default",
             name: :warehouses_default_index
           )
  end
end
