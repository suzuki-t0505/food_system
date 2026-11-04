defmodule FoodVault.Repo.Migrations.CreateInventoryTransactions do
  use Ecto.Migration

  def up do
    create table(:inventory_transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:inventory_lots, type: :binary_id, on_delete: :nothing), null: false
      add :transaction_type, :string, null: false
      add :case_diff, :integer, null: false
      add :piece_diff, :integer, null: false

      # 出庫オーダー(shipment_orders)は単位 C で作る。FK はそのときの migration で追加する
      add :shipment_order_id, :binary_id
      add :transfer_id, :binary_id
      add :note, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :operator, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:inventory_transactions, [:lot_id])
    create index(:inventory_transactions, [:shipment_order_id])
    create index(:inventory_transactions, [:transfer_id])
    create index(:inventory_transactions, [:user_id])
    create index(:inventory_transactions, [:inserted_at])

    create constraint(:inventory_transactions, :actor_present,
             check: "user_id IS NOT NULL OR operator IS NOT NULL"
           )

    create constraint(:inventory_transactions, :diff_not_zero,
             check: "case_diff <> 0 OR piece_diff <> 0"
           )

    # 追記専用テーブルの更新・削除を DB で拒否する(単位 C の shipment_order_events でも使う)
    execute """
            CREATE FUNCTION forbid_update_delete() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION forbid_update_delete()"

    execute """
            CREATE TRIGGER inventory_transactions_append_only
            BEFORE UPDATE OR DELETE ON inventory_transactions
            FOR EACH ROW EXECUTE FUNCTION forbid_update_delete()
            """,
            "DROP TRIGGER inventory_transactions_append_only ON inventory_transactions"
  end

  def down do
    execute "DROP TRIGGER inventory_transactions_append_only ON inventory_transactions"
    execute "DROP FUNCTION forbid_update_delete()"
    drop table(:inventory_transactions)
  end
end
