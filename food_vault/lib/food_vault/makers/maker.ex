defmodule FoodVault.Makers.Maker do
  @moduledoc "メーカー。削除せず `archived_at` でアーカイブする。"

  use FoodVault.Schema
  import Ecto.Changeset

  schema "makers" do
    field :maker_code, :string
    field :maker_name, :string
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "登録・編集用。"
  def changeset(maker, attrs) do
    maker
    |> cast(attrs, [:maker_code, :maker_name])
    |> update_change(:maker_code, &trim/1)
    |> update_change(:maker_name, &trim/1)
    |> validate_required([:maker_code, :maker_name])
    |> validate_length(:maker_code, max: 50)
    |> validate_length(:maker_name, max: 255)
    |> unique_constraint(:maker_code)
  end

  def archive_changeset(maker), do: change(maker, archived_at: DateTime.utc_now(:second))
  def restore_changeset(maker), do: change(maker, archived_at: nil)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
