defmodule FoodShip.Repo.Migrations.CreateClientsShippingItemsExpirationRules do
  use Ecto.Migration

  def change do
    create table(:clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_code, :string, null: false
      add :client_name, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:clients, [:client_code])

    # inventory_item_id・inventory_maker_id は在庫側の ID(FK ではなく ULID のコピー)
    create table(:shipping_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :inventory_item_id, :binary_id, null: false
      add :item_code, :string, null: false
      add :inventory_maker_id, :binary_id, null: false
      add :maker_name, :string, null: false
      add :item_name, :string, null: false
      add :boxes_per_order, :integer, null: false, default: 1
      add :pieces_per_order, :integer, null: false, default: 1
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shipping_items, [:inventory_item_id])
    create unique_index(:shipping_items, [:item_code])
    create constraint(:shipping_items, :boxes_per_order_positive, check: "boxes_per_order >= 1")
    create constraint(:shipping_items, :pieces_per_order_positive, check: "pieces_per_order >= 1")

    create table(:expiration_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_id, references(:clients, type: :binary_id, on_delete: :nothing), null: false

      add :shipping_item_id, references(:shipping_items, type: :binary_id, on_delete: :nothing),
        null: false

      add :min_remaining_days, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:expiration_rules, [:client_id, :shipping_item_id])
    create index(:expiration_rules, [:shipping_item_id])

    create constraint(:expiration_rules, :min_remaining_days_non_negative,
             check: "min_remaining_days >= 0"
           )
  end
end
