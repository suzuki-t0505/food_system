defmodule FoodShip.Repo.Migrations.CreateShippingSlips do
  use Ecto.Migration

  def change do
    # 伝票番号(`S-000123` 表示)。DB シーケンスで採番する(読み取り専用)
    execute(
      "CREATE SEQUENCE shipping_slips_slip_no_seq",
      "DROP SEQUENCE IF EXISTS shipping_slips_slip_no_seq"
    )

    create table(:shipping_slips, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :slip_no, :integer,
        null: false,
        default: fragment("nextval('shipping_slips_slip_no_seq')")

      add :client_id, references(:clients, type: :binary_id, on_delete: :nothing), null: false

      add :shipping_item_id, references(:shipping_items, type: :binary_id, on_delete: :nothing),
        null: false

      add :client_slip_no, :string
      add :scheduled_ship_date, :date, null: false
      add :order_count, :integer, null: false
      add :box_count, :integer, null: false
      add :total_piece_qty, :integer, null: false
      add :min_expiration_date, :date

      # 在庫側 shipment_orders.id(FK ではない)。引当解除に成功したら NULL に戻す
      add :inventory_order_id, :binary_id
      add :status, :string, null: false, default: "pending"
      add :shortage_pieces, :integer
      add :allocation_error, :string

      # 同じ伝票の同時操作を見分けるため、マイクロ秒まで持つ(functional-design の `utc_datetime` からの変更)
      add :allocation_attempted_at, :utc_datetime_usec
      add :input_source, :string, null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nothing),
        null: false

      add :packed_by_user_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :packed_at, :utc_datetime
      add :cancelled_by_user_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :cancelled_at, :utc_datetime
      add :reversed_by_user_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :reversed_at, :utc_datetime
      add :reverse_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shipping_slips, [:slip_no])

    # 取消・出庫取消済みを除いて、同じ発注元伝票番号の同じ商品の二重登録を防ぐ
    create unique_index(:shipping_slips, [:client_id, :client_slip_no, :shipping_item_id],
             where: "client_slip_no IS NOT NULL AND status NOT IN ('cancelled', 'reversed')",
             name: :shipping_slips_client_slip_no_active_index
           )

    create index(:shipping_slips, [:scheduled_ship_date, :status])
    create index(:shipping_slips, [:client_id])
    create index(:shipping_slips, [:shipping_item_id])
    create index(:shipping_slips, [:inventory_order_id])
    create index(:shipping_slips, [:status, :allocation_attempted_at])
    create index(:shipping_slips, [:created_by_user_id])
    create index(:shipping_slips, [:packed_by_user_id])
    create index(:shipping_slips, [:cancelled_by_user_id])
    create index(:shipping_slips, [:reversed_by_user_id])

    create constraint(:shipping_slips, :order_count_positive, check: "order_count > 0")
    create constraint(:shipping_slips, :box_count_positive, check: "box_count >= 1")
    create constraint(:shipping_slips, :total_piece_qty_positive, check: "total_piece_qty > 0")

    create constraint(:shipping_slips, :order_id_required_when_allocated,
             check:
               "status NOT IN ('allocated', 'packed', 'reversed') OR inventory_order_id IS NOT NULL"
           )

    create constraint(:shipping_slips, :packed_columns_required,
             check:
               "status <> 'packed' OR (packed_at IS NOT NULL AND packed_by_user_id IS NOT NULL)"
           )

    create constraint(:shipping_slips, :cancelled_columns_required,
             check:
               "status <> 'cancelled' OR (cancelled_at IS NOT NULL AND cancelled_by_user_id IS NOT NULL)"
           )

    create constraint(:shipping_slips, :reversed_columns_required,
             check:
               "status <> 'reversed' OR (reversed_at IS NOT NULL AND reversed_by_user_id IS NOT NULL AND reverse_reason IS NOT NULL)"
           )

    create constraint(:shipping_slips, :shortage_pieces_only_when_shortage,
             check: "status = 'shortage' OR shortage_pieces IS NULL"
           )

    # 引当ロットの表示用キャッシュ(在庫の正は在庫側)
    create table(:slip_allocated_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :shipping_slip_id, references(:shipping_slips, type: :binary_id, on_delete: :nothing),
        null: false

      # 在庫側 inventory_lots.id(FK ではない)。期限なしは 9999-12-31
      add :inventory_lot_id, :binary_id, null: false
      add :expiration_date, :date, null: false
      add :allocated_pieces, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:slip_allocated_lots, [:shipping_slip_id, :inventory_lot_id])

    create constraint(:slip_allocated_lots, :allocated_pieces_positive,
             check: "allocated_pieces > 0"
           )
  end
end
