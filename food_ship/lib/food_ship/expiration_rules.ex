defmodule FoodShip.ExpirationRules do
  @moduledoc """
  出荷期限ルール(発注元 × 発送商品の最低残日数)。

  書き込み関数は先頭引数に `FoodShip.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。アーカイブ済みの発注元・発送商品には
  登録できない。ルールは物理削除してよい(伝票は引当時の値を保持するため)。
  """

  import Ecto.Query, warn: false

  alias FoodShip.Clients.Client
  alias FoodShip.ExpirationRules.ExpirationRule
  alias FoodShip.Repo
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.Utils.Permission

  @doc "ルールの一覧(発注元コード・商品コード順。発注元・発送商品を preload 済み)。"
  def list_expiration_rules do
    ExpirationRule
    |> join(:inner, [r], c in assoc(r, :client))
    |> join(:inner, [r, _c], i in assoc(r, :shipping_item))
    |> order_by([_r, c, i], asc: c.client_code, asc: i.item_code)
    |> preload([_r, c, i], client: c, shipping_item: i)
    |> Repo.all()
  end

  @doc "ルールを取得する(発注元・発送商品を preload 済み)。"
  def get_expiration_rule!(id) do
    ExpirationRule |> Repo.get!(id) |> Repo.preload([:client, :shipping_item])
  end

  @doc "発注元 × 発送商品のルール。無ければ `nil`(制限なし)。"
  def get_rule(client_id, shipping_item_id) do
    Repo.get_by(ExpirationRule, client_id: client_id, shipping_item_id: shipping_item_id)
  end

  @doc "フォーム用の changeset。"
  def change_expiration_rule(rule, attrs \\ %{})

  def change_expiration_rule(%ExpirationRule{id: nil} = rule, attrs),
    do: ExpirationRule.create_changeset(rule, attrs)

  def change_expiration_rule(%ExpirationRule{} = rule, attrs),
    do: ExpirationRule.update_changeset(rule, attrs)

  @doc "ルールを登録する。アーカイブ済みの発注元・発送商品は選べない。"
  def create_expiration_rule(scope, attrs) do
    with :ok <- authorize(scope) do
      changeset = ExpirationRule.create_changeset(%ExpirationRule{}, attrs)

      changeset
      |> validate_active(:client_id, Client)
      |> validate_active(:shipping_item_id, ShippingItem)
      |> Repo.insert()
    end
  end

  @doc "最低残日数を更新する。"
  def update_expiration_rule(scope, %ExpirationRule{} = rule, attrs) do
    with :ok <- authorize(scope) do
      rule |> ExpirationRule.update_changeset(attrs) |> Repo.update()
    end
  end

  @doc "ルールを削除する(物理削除)。"
  def delete_expiration_rule(scope, %ExpirationRule{} = rule) do
    with :ok <- authorize(scope), do: Repo.delete(rule)
  end

  # 存在しない・アーカイブ済みの参照先は changeset エラーにする
  defp validate_active(changeset, field, schema) do
    id = Ecto.Changeset.get_field(changeset, field)

    cond do
      # 必須・形式のエラーが既にあるときは重ねない
      Keyword.has_key?(changeset.errors, field) -> changeset
      match?(%{archived_at: nil}, Repo.get(schema, id)) -> changeset
      true -> Ecto.Changeset.add_error(changeset, field, "は選べません。")
    end
  end

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
