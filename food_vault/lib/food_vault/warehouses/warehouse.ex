defmodule FoodVault.Warehouses.Warehouse do
  @moduledoc "倉庫。削除せず `archived_at` でアーカイブする。"

  use FoodVault.Schema
  import Ecto.Changeset

  schema "warehouses" do
    field :warehouse_code, :string
    field :warehouse_name, :string
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

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

  def archive_changeset(warehouse), do: change(warehouse, archived_at: DateTime.utc_now(:second))
  def restore_changeset(warehouse), do: change(warehouse, archived_at: nil)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
