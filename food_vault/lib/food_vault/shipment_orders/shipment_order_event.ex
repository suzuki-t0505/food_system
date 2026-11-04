defmodule FoodVault.ShipmentOrders.ShipmentOrderEvent do
  @moduledoc """
  出庫オーダーの履歴(追記専用)。状態遷移ごとに 1 行を追加する。

  更新・削除の関数は作らない。DB 側にも UPDATE / DELETE を拒否するトリガーがある。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.Accounts.User
  alias FoodVault.ShipmentOrders.ShipmentOrder

  @types [:created, :shipped, :cancelled, :reversed]
  @type_labels %{created: "引当", shipped: "出庫確定", cancelled: "引当解除", reversed: "出庫取消"}

  schema "shipment_order_events" do
    belongs_to :shipment_order, ShipmentOrder
    field :event_type, Ecto.Enum, values: @types
    belongs_to :user, User
    field :operator, :string
    field :reason, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "履歴の種別の表示名。"
  def event_type_label(type), do: Map.fetch!(@type_labels, type)

  @doc "追加用の changeset。これが唯一の書き込み経路。"
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:shipment_order_id, :event_type, :user_id, :operator, :reason])
    |> validate_required([:shipment_order_id, :event_type])
    |> validate_length(:operator, max: 255)
    |> validate_actor()
    |> check_constraint(:user_id, name: :actor_present)
  end

  defp validate_actor(changeset) do
    if is_nil(get_field(changeset, :user_id)) and is_nil(get_field(changeset, :operator)) do
      add_error(changeset, :user_id, "操作者が必要です")
    else
      changeset
    end
  end
end
