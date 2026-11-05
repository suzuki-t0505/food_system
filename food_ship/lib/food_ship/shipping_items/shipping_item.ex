defmodule FoodShip.ShippingItems.ShippingItem do
  @moduledoc """
  発送商品。在庫側の商品(`items`)と 1 対 1 で、在庫側の値(`item_code`・`item_name`・
  `inventory_maker_id`・`maker_name`)は取得時点のコピー(自動同期しない)。

  在庫側の ID は FK ではなく ULID として保持する。削除せず `archived_at` でアーカイブする。

    * `create_changeset/2` - 登録(在庫側から取得した値＋換算)
    * `update_changeset/2` - 編集(換算のみ。在庫側の値は変えない)
    * `refresh_changeset/2` - 在庫側の値の再取得
  """

  use FoodShip.Schema
  import Ecto.Changeset

  schema "shipping_items" do
    field :inventory_item_id, Ecto.ULID
    field :item_code, :string
    field :inventory_maker_id, Ecto.ULID
    field :maker_name, :string
    field :item_name, :string
    field :boxes_per_order, :integer, default: 1
    field :pieces_per_order, :integer, default: 1
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @inventory_fields [:item_code, :inventory_maker_id, :maker_name, :item_name]
  @conversion_fields [:boxes_per_order, :pieces_per_order]

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "登録用。`inventory_item_id` は登録時だけ受け付ける。"
  def create_changeset(shipping_item, attrs) do
    shipping_item
    |> cast(attrs, [:inventory_item_id | @inventory_fields] ++ @conversion_fields)
    |> validate_required([:inventory_item_id | @inventory_fields])
    |> validate_conversion()
    |> validate_lengths()
    |> unsafe_validate_unique(:item_code, FoodShip.Repo)
    |> unique_constraint(:item_code)
    |> unsafe_validate_unique(:inventory_item_id, FoodShip.Repo)
    |> unique_constraint(:inventory_item_id)
  end

  @doc "編集用(換算のみ)。"
  def update_changeset(shipping_item, attrs) do
    shipping_item
    |> cast(attrs, @conversion_fields)
    |> validate_conversion()
  end

  @doc "在庫側の値の再取得用。商品コードの重複は拒否する。"
  def refresh_changeset(shipping_item, attrs) do
    shipping_item
    |> cast(attrs, @inventory_fields)
    |> validate_required(@inventory_fields)
    |> validate_lengths()
    |> unsafe_validate_unique(:item_code, FoodShip.Repo)
    |> unique_constraint(:item_code)
  end

  def archive_changeset(shipping_item),
    do: change(shipping_item, archived_at: DateTime.utc_now(:second))

  def restore_changeset(shipping_item), do: change(shipping_item, archived_at: nil)

  defp validate_conversion(changeset) do
    changeset
    |> validate_required(@conversion_fields)
    |> validate_number(:boxes_per_order, greater_than_or_equal_to: 1)
    |> validate_number(:pieces_per_order, greater_than_or_equal_to: 1)
    |> check_constraint(:boxes_per_order, name: :boxes_per_order_positive)
    |> check_constraint(:pieces_per_order, name: :pieces_per_order_positive)
  end

  defp validate_lengths(changeset) do
    changeset
    |> validate_length(:item_code, max: 100)
    |> validate_length(:item_name, max: 255)
    |> validate_length(:maker_name, max: 255)
  end
end
