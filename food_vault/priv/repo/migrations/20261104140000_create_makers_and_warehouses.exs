defmodule FoodVault.Repo.Migrations.CreateMakersAndWarehouses do
  use Ecto.Migration

  def change do
    create table(:makers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :maker_code, :string, null: false
      add :maker_name, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:makers, [:maker_code])

    create table(:warehouses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :warehouse_code, :string, null: false
      add :warehouse_name, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:warehouses, [:warehouse_code])
  end
end
