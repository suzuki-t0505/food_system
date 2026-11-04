defmodule FoodVault.ShipmentOrders.ShipmentOrderLine do
  @moduledoc "出庫オーダーの明細(1 オーダーに同じ商品は 1 行)。"

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.Items.Item
  alias FoodVault.ShipmentOrders.{ShipmentAllocation, ShipmentOrder}

  schema "shipment_order_lines" do
    belongs_to :shipment_order, ShipmentOrder
    belongs_to :item, Item
    field :req_cases, :integer, default: 0
    field :req_pieces, :integer, default: 0
    field :min_expiration_date, :date

    has_many :allocations, ShipmentAllocation

    timestamps(type: :utc_datetime)
  end

  def create_changeset(line, attrs) do
    line
    |> cast(attrs, [:shipment_order_id, :item_id, :req_cases, :req_pieces, :min_expiration_date])
    |> validate_required([:shipment_order_id, :item_id, :req_cases, :req_pieces])
    |> check_constraint(:req_cases, name: :req_present)
    |> unique_constraint([:shipment_order_id, :item_id])
  end
end
