defmodule FoodVault.ShipmentOrders.ShipmentAllocation do
  @moduledoc """
  引当明細(明細 × ロット)。同じロットは 1 行に加算する。

  引当解除でも削除しない(どのロットを引き当てていたかの記録として残す)。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.ShipmentOrders.ShipmentOrderLine

  schema "shipment_allocations" do
    belongs_to :shipment_order_line, ShipmentOrderLine
    belongs_to :lot, InventoryLot
    field :allocated_cases, :integer, default: 0
    field :allocated_pieces, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def create_changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:shipment_order_line_id, :lot_id, :allocated_cases, :allocated_pieces])
    |> validate_required([:shipment_order_line_id, :lot_id, :allocated_cases, :allocated_pieces])
    |> check_constraint(:allocated_cases, name: :allocated_present)
    |> unique_constraint([:shipment_order_line_id, :lot_id])
  end
end
