defmodule FoodShip.ExpirationRules.ExpirationRule do
  @moduledoc """
  出荷期限ルール(発注元 × 発送商品の最低残日数)。

  最低許容期限日 = 出荷予定日 + `min_remaining_days`。未登録は制限なし。
  伝票は引当時の値を保持するため、物理削除してよい。
  """

  use FoodShip.Schema
  import Ecto.Changeset

  alias FoodShip.Clients.Client
  alias FoodShip.ShippingItems.ShippingItem

  schema "expiration_rules" do
    field :min_remaining_days, :integer

    belongs_to :client, Client
    belongs_to :shipping_item, ShippingItem

    timestamps(type: :utc_datetime)
  end

  @doc "登録用。発注元・発送商品は登録時だけ受け付ける。"
  def create_changeset(rule, attrs) do
    rule
    |> cast(attrs, [:client_id, :shipping_item_id, :min_remaining_days])
    |> validate_required([:client_id, :shipping_item_id])
    |> validate_days()
    |> unsafe_validate_unique([:client_id, :shipping_item_id], FoodShip.Repo,
      error_key: :shipping_item_id,
      message: "は、この発注元ですでに登録されています。"
    )
    |> unique_constraint(:shipping_item_id,
      name: :expiration_rules_client_id_shipping_item_id_index,
      message: "は、この発注元ですでに登録されています。"
    )
    |> assoc_constraint(:client)
    |> assoc_constraint(:shipping_item)
  end

  @doc "編集用(最低残日数のみ)。"
  def update_changeset(rule, attrs) do
    rule
    |> cast(attrs, [:min_remaining_days])
    |> validate_days()
  end

  defp validate_days(changeset) do
    changeset
    |> validate_required([:min_remaining_days])
    |> validate_number(:min_remaining_days, greater_than_or_equal_to: 0)
    |> check_constraint(:min_remaining_days, name: :min_remaining_days_non_negative)
  end
end
