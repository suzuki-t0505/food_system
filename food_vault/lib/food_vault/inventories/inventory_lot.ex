defmodule FoodVault.Inventories.InventoryLot do
  @moduledoc """
  ロット(倉庫 × 商品 × 期限日 × 入荷日)。在庫 0 になっても行は削除しない。

  期限なしの商品は `expiration_date` を `9999-12-31` で保存する。
  有効在庫は `FoodVault.Utils.Calc.effective/2` で求める。
  """

  use FoodVault.Schema

  alias FoodVault.Items.Item
  alias FoodVault.Warehouses.Warehouse

  schema "inventory_lots" do
    belongs_to :warehouse, Warehouse
    belongs_to :item, Item
    field :expiration_date, :date
    field :received_date, :date
    field :case_qty, :integer, default: 0
    field :piece_qty, :integer, default: 0
    field :allocated_case_qty, :integer, default: 0
    field :allocated_piece_qty, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
