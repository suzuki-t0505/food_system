defmodule FoodVault.ShipmentOrders.ShipmentOrder do
  @moduledoc """
  出庫オーダー。状態は `allocated` → `shipped` / `cancelled`、`shipped` → `reversed`(P1)。

  `external_slip_id` がある(NULL でない)オーダーは発送システム起源、NULL は画面登録。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.ShipmentOrders.{ShipmentOrderEvent, ShipmentOrderLine}
  alias FoodVault.Warehouses.Warehouse

  @statuses [:allocated, :shipped, :cancelled, :reversed]
  @status_labels %{
    allocated: "引当済",
    shipped: "出庫済",
    cancelled: "取消",
    reversed: "出庫取消済"
  }

  schema "shipment_orders" do
    belongs_to :warehouse, Warehouse
    field :shipment_date, :date
    field :status, Ecto.Enum, values: @statuses, default: :allocated
    field :external_slip_id, :string
    field :shipped_at, :utc_datetime

    has_many :lines, ShipmentOrderLine
    has_many :events, ShipmentOrderEvent

    timestamps(type: :utc_datetime)
  end

  @doc "状態の一覧。"
  def statuses, do: @statuses

  @doc "状態の表示名。"
  def status_label(status), do: Map.fetch!(@status_labels, status)

  @doc "起源。`external_slip_id` があれば発送システム(`:external`)、なければ画面(`:screen`)。"
  def origin(%__MODULE__{external_slip_id: nil}), do: :screen
  def origin(%__MODULE__{}), do: :external

  @doc "起源の表示名。"
  def origin_label(:screen), do: "画面登録"
  def origin_label(:external), do: "発送システム"

  @doc "引当時の登録用 changeset。"
  def create_changeset(order, attrs) do
    order
    |> cast(attrs, [:warehouse_id, :shipment_date, :external_slip_id])
    |> validate_required([:warehouse_id, :shipment_date])
    |> validate_length(:external_slip_id, max: 255)
    |> unique_constraint(:external_slip_id, name: :shipment_orders_external_slip_id_active_index)
    |> foreign_key_constraint(:warehouse_id)
  end

  def ship_changeset(order),
    do: change(order, status: :shipped, shipped_at: DateTime.utc_now(:second))

  def cancel_changeset(order), do: change(order, status: :cancelled)
end
