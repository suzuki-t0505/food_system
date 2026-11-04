defmodule FoodVault.Repo.Migrations.CreateShipmentOrders do
  use Ecto.Migration

  def change do
    create table(:shipment_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :warehouse_id, references(:warehouses, type: :binary_id, on_delete: :nothing),
        null: false

      add :shipment_date, :date, null: false
      add :status, :string, null: false, default: "allocated"
      add :external_slip_id, :string
      add :shipped_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:shipment_orders, [:warehouse_id, :shipment_date])
    create index(:shipment_orders, [:status])

    # 取消済みを除いて external_slip_id を一意にする(数量変更で「取消 → 同じ ID で再引当」を許すため)
    create unique_index(:shipment_orders, [:external_slip_id],
             where: "external_slip_id IS NOT NULL AND status <> 'cancelled'",
             name: :shipment_orders_external_slip_id_active_index
           )

    create table(:shipment_order_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :shipment_order_id, references(:shipment_orders, type: :binary_id, on_delete: :nothing),
        null: false

      add :item_id, references(:items, type: :binary_id, on_delete: :nothing), null: false
      add :req_cases, :integer, null: false, default: 0
      add :req_pieces, :integer, null: false, default: 0
      add :min_expiration_date, :date

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shipment_order_lines, [:shipment_order_id, :item_id])
    create index(:shipment_order_lines, [:item_id])
    create constraint(:shipment_order_lines, :req_cases_non_negative, check: "req_cases >= 0")
    create constraint(:shipment_order_lines, :req_pieces_non_negative, check: "req_pieces >= 0")

    create constraint(:shipment_order_lines, :req_present, check: "req_cases + req_pieces > 0")

    create table(:shipment_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :shipment_order_line_id,
          references(:shipment_order_lines, type: :binary_id, on_delete: :nothing),
          null: false

      add :lot_id, references(:inventory_lots, type: :binary_id, on_delete: :nothing), null: false
      add :allocated_cases, :integer, null: false, default: 0
      add :allocated_pieces, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shipment_allocations, [:shipment_order_line_id, :lot_id])
    create index(:shipment_allocations, [:lot_id])

    create constraint(:shipment_allocations, :allocated_cases_non_negative,
             check: "allocated_cases >= 0"
           )

    create constraint(:shipment_allocations, :allocated_pieces_non_negative,
             check: "allocated_pieces >= 0"
           )

    create constraint(:shipment_allocations, :allocated_present,
             check: "allocated_cases + allocated_pieces > 0"
           )

    create table(:shipment_order_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :shipment_order_id, references(:shipment_orders, type: :binary_id, on_delete: :nothing),
        null: false

      add :event_type, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :operator, :string
      add :reason, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:shipment_order_events, [:shipment_order_id])

    create constraint(:shipment_order_events, :actor_present,
             check: "user_id IS NOT NULL OR operator IS NOT NULL"
           )

    execute """
            CREATE TRIGGER shipment_order_events_append_only
            BEFORE UPDATE OR DELETE ON shipment_order_events
            FOR EACH ROW EXECUTE FUNCTION forbid_update_delete()
            """,
            "DROP TRIGGER shipment_order_events_append_only ON shipment_order_events"

    # 受払履歴 → 出庫オーダーの参照(受払履歴の migration では shipment_orders がまだ無い)
    alter table(:inventory_transactions) do
      modify :shipment_order_id,
             references(:shipment_orders, type: :binary_id, on_delete: :nothing), from: :binary_id
    end
  end
end
