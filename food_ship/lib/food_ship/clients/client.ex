defmodule FoodShip.Clients.Client do
  @moduledoc "発注元。削除せず `archived_at` でアーカイブする。画面・帳票では「発注元」と呼ぶ。"

  use FoodShip.Schema
  import Ecto.Changeset

  schema "clients" do
    field :client_code, :string
    field :client_name, :string
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "アーカイブ済みか。"
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "登録・編集用。"
  def changeset(client, attrs) do
    client
    |> cast(attrs, [:client_code, :client_name])
    |> update_change(:client_code, &trim/1)
    |> update_change(:client_name, &trim/1)
    |> validate_required([:client_code, :client_name])
    |> validate_length(:client_code, max: 50)
    |> validate_length(:client_name, max: 255)
    |> unsafe_validate_unique(:client_code, FoodShip.Repo)
    |> unique_constraint(:client_code)
  end

  def archive_changeset(client), do: change(client, archived_at: DateTime.utc_now(:second))
  def restore_changeset(client), do: change(client, archived_at: nil)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
