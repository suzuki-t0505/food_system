defmodule FoodVault.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :maker_id, references(:makers, type: :binary_id, on_delete: :nothing), null: false
      add :item_code, :string, null: false
      add :item_name, :string, null: false
      add :units_per_case, :integer, null: false
      add :expiration_type, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:item_code])
    create index(:items, [:maker_id])
    create constraint(:items, :units_per_case_positive, check: "units_per_case >= 1")
  end
end
