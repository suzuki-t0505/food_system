defmodule FoodVault.Items.Item do
  @moduledoc """
  商品。削除せず `archived_at` でアーカイブする。

  `units_per_case`(ケース入数)と `expiration_type`(期限区分)は、ロット(在庫 0 を含む)が
  存在すると変更できない。この検査は `FoodVault.Items.update_item/3` が行う。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  alias FoodVault.Makers.Maker

  @expiration_types [:consumption, :best_before, :none]
  @expiration_type_labels %{consumption: "消費期限", best_before: "賞味期限", none: "管理なし"}

  schema "items" do
    belongs_to :maker, Maker
    field :item_code, :string
    field :item_name, :string
    field :units_per_case, :integer
    field :expiration_type, Ecto.Enum, values: @expiration_types
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "期限区分の一覧。"
  def expiration_types, do: @expiration_types

  @doc "期限区分の表示名。"
  def expiration_type_label(type), do: Map.fetch!(@expiration_type_labels, type)

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "入数・期限区分を変更する changeset か。"
  def locked_fields_changed?(%Ecto.Changeset{changes: changes}) do
    Map.has_key?(changes, :units_per_case) or Map.has_key?(changes, :expiration_type)
  end

  @doc "登録・編集用。"
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:maker_id, :item_code, :item_name, :units_per_case, :expiration_type])
    |> update_change(:item_code, &trim/1)
    |> update_change(:item_name, &trim/1)
    |> validate_required([:maker_id, :item_code, :item_name, :units_per_case, :expiration_type])
    |> validate_length(:item_code, max: 50)
    |> validate_length(:item_name, max: 255)
    |> validate_number(:units_per_case, greater_than_or_equal_to: 1)
    |> unique_constraint(:item_code)
    |> foreign_key_constraint(:maker_id)
    |> check_constraint(:units_per_case, name: :units_per_case_positive)
  end

  def archive_changeset(item), do: change(item, archived_at: DateTime.utc_now(:second))
  def restore_changeset(item), do: change(item, archived_at: nil)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
