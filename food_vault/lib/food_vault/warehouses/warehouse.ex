defmodule FoodVault.Warehouses.Warehouse do
  @moduledoc """
  倉庫。削除せず `archived_at` でアーカイブする。

  `is_default` はデフォルト倉庫(発送システムの引当先)。常に 0 件または 1 件で、
  `Warehouses.set_default_warehouse/2` でだけ変更する(`changeset/2` では変えられない)。
  """

  use FoodVault.Schema
  import Ecto.Changeset

  schema "warehouses" do
    field :warehouse_code, :string
    field :warehouse_name, :string
    field :is_default, :boolean, default: false
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "デフォルト倉庫か。"
  def default?(%__MODULE__{is_default: is_default}), do: is_default == true

  @doc "登録・編集用。"
  def changeset(warehouse, attrs) do
    warehouse
    |> cast(attrs, [:warehouse_code, :warehouse_name])
    |> update_change(:warehouse_code, &trim/1)
    |> update_change(:warehouse_name, &trim/1)
    |> validate_required([:warehouse_code, :warehouse_name])
    |> validate_length(:warehouse_code, max: 50)
    |> validate_length(:warehouse_name, max: 255)
    |> unique_constraint(:warehouse_code)
  end

  @doc "デフォルト倉庫にする。他のデフォルトの解除は呼び出し側(`Warehouses`)で先に行う。"
  def default_changeset(warehouse) do
    warehouse
    |> change(is_default: true)
    |> unique_constraint(:is_default, name: :warehouses_default_index)
  end

  def archive_changeset(warehouse), do: change(warehouse, archived_at: DateTime.utc_now(:second))
  def restore_changeset(warehouse), do: change(warehouse, archived_at: nil)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
