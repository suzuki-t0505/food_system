defmodule FoodShip.ShippingSlips.SlipAllocatedLot do
  @moduledoc """
  伝票の引当ロット(表示用キャッシュ。在庫の正は在庫側)。

  在庫側のロット ID は FK ではなく ULID として保持する。期限なしの商品は `9999-12-31`。
  再引当・解除・取消では、同一トランザクションで旧行を削除して新行を保存する。
  発送側は常に `req_cases = 0` で要求するため、ケース引当は保存しない(バラ数のみ)。
  """

  use FoodShip.Schema

  alias FoodShip.ShippingSlips.ShippingSlip

  schema "slip_allocated_lots" do
    field :inventory_lot_id, Ecto.ULID
    field :expiration_date, :date
    field :allocated_pieces, :integer

    belongs_to :shipping_slip, ShippingSlip

    timestamps(type: :utc_datetime)
  end

  @no_expiration ~D[9999-12-31]

  @doc "期限なし(`9999-12-31`)か。"
  def no_expiration?(%__MODULE__{expiration_date: date}), do: date == @no_expiration

  @doc "期限日の表示。期限なし(`9999-12-31`)は「期限なし」。"
  def expiration_label(%Date{} = date) when date == @no_expiration, do: "期限なし"
  def expiration_label(%Date{} = date), do: Date.to_iso8601(date)
end
