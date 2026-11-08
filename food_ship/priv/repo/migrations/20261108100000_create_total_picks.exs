defmodule FoodShip.Repo.Migrations.CreateTotalPicks do
  use Ecto.Migration

  def change do
    # ピック番号(`TP-000045` 表示)。DB シーケンスで採番する(読み取り専用)
    execute(
      "CREATE SEQUENCE total_picks_pick_no_seq",
      "DROP SEQUENCE IF EXISTS total_picks_pick_no_seq"
    )

    create table(:total_picks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pick_no, :integer,
        null: false,
        default: fragment("nextval('total_picks_pick_no_seq')")

      add :scheduled_ship_date, :date, null: false
      add :client_id, references(:clients, type: :binary_id, on_delete: :nothing), null: false

      # 在庫側 makers.id(FK ではない)と、作成時点のメーカー名
      add :inventory_maker_id, :binary_id, null: false
      add :maker_name, :string, null: false

      add :status, :string, null: false, default: "issued"
      add :revision, :integer, null: false, default: 1
      add :issued_at, :utc_datetime, null: false

      add :issued_by_user_id, references(:users, type: :binary_id, on_delete: :nothing),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:total_picks, [:pick_no])
    create index(:total_picks, [:scheduled_ship_date, :status])
    create index(:total_picks, [:client_id])
    create index(:total_picks, [:inventory_maker_id])
    create index(:total_picks, [:issued_by_user_id])

    create constraint(:total_picks, :revision_positive, check: "revision >= 1")

    create constraint(:total_picks, :status_valid,
             check: "status IN ('issued', 'outdated', 'cancelled')"
           )

    # 後方互換: NULL 可の列の追加。旧コードは列を知らないだけで動く
    alter table(:shipping_slips) do
      add :total_pick_id, references(:total_picks, type: :binary_id, on_delete: :nothing)
    end

    create index(:shipping_slips, [:total_pick_id])

    # 作成時に紐づくのは `allocated` のみ。`packed` でも外さない。取消・変更で外すときは
    # 同じ UPDATE で `status` と `total_pick_id` を更新する
    create constraint(:shipping_slips, :total_pick_only_when_picked,
             check: "total_pick_id IS NULL OR status IN ('allocated', 'packed')"
           )
  end
end
