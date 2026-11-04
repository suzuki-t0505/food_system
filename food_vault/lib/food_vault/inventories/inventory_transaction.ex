defmodule FoodVault.Inventories.InventoryTransaction do
  @moduledoc """
  受払履歴(追記専用)。現在庫が変わる操作ごとに 1 行を追加する。

  更新・削除の changeset と関数は作らない。DB 側にも UPDATE / DELETE を拒否する
  トリガーがある。操作者は画面のユーザー(`user_id`)か API の `operator` のどちらか。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.Accounts.User
  alias FoodVault.Inventories.InventoryLot

  @types [:receive, :ship, :ship_reverse, :auto_break, :transfer_out, :transfer_in, :adjust]
  @type_labels %{
    receive: "入荷",
    ship: "出庫",
    ship_reverse: "出庫取消",
    auto_break: "荷崩し",
    transfer_out: "移動出庫",
    transfer_in: "移動入庫",
    adjust: "棚卸調整"
  }

  schema "inventory_transactions" do
    belongs_to :lot, InventoryLot
    field :transaction_type, Ecto.Enum, values: @types
    field :case_diff, :integer
    field :piece_diff, :integer
    field :shipment_order_id, Ecto.ULID
    field :transfer_id, Ecto.ULID
    field :note, :string
    belongs_to :user, User
    field :operator, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "処理区分の一覧。"
  def transaction_types, do: @types

  @doc "処理区分の表示名。"
  def transaction_type_label(type), do: Map.fetch!(@type_labels, type)

  @doc "追加用の changeset。これが唯一の書き込み経路。"
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :lot_id,
      :transaction_type,
      :case_diff,
      :piece_diff,
      :shipment_order_id,
      :transfer_id,
      :note,
      :user_id,
      :operator
    ])
    |> validate_required([:lot_id, :transaction_type, :case_diff, :piece_diff])
    |> validate_length(:operator, max: 255)
    |> validate_actor()
    |> check_constraint(:user_id, name: :actor_present)
    |> check_constraint(:case_diff, name: :diff_not_zero)
    |> foreign_key_constraint(:lot_id)
  end

  defp validate_actor(changeset) do
    if is_nil(get_field(changeset, :user_id)) and is_nil(get_field(changeset, :operator)) do
      add_error(changeset, :user_id, "操作者が必要です")
    else
      changeset
    end
  end
end
