defmodule FoodVault.Repo.Migrations.CreateInventoryLots do
  use Ecto.Migration

  def change do
    create table(:inventory_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :warehouse_id, references(:warehouses, type: :binary_id, on_delete: :nothing),
        null: false

      add :item_id, references(:items, type: :binary_id, on_delete: :nothing), null: false
      add :expiration_date, :date, null: false
      add :received_date, :date, null: false
      add :case_qty, :integer, null: false, default: 0
      add :piece_qty, :integer, null: false, default: 0
      add :allocated_case_qty, :integer, null: false, default: 0
      add :allocated_piece_qty, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :inventory_lots,
             [:warehouse_id, :item_id, :expiration_date, :received_date],
             name: :inventory_lots_lot_key_index
           )

    create index(:inventory_lots, [:item_id])

    create constraint(:inventory_lots, :case_qty_non_negative, check: "case_qty >= 0")
    create constraint(:inventory_lots, :piece_qty_non_negative, check: "piece_qty >= 0")

    create constraint(:inventory_lots, :allocated_case_qty_in_range,
             check: "allocated_case_qty >= 0 AND allocated_case_qty <= case_qty"
           )

    create constraint(:inventory_lots, :allocated_piece_qty_in_range,
             check: "allocated_piece_qty >= 0 AND allocated_piece_qty <= piece_qty"
           )
  end
end
