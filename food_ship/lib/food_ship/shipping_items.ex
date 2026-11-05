defmodule FoodShip.ShippingItems do
  @moduledoc """
  発送商品マスタ。在庫側の商品と 1 対 1 で、在庫側の値は取得時点のコピー(自動同期しない)。

  書き込み関数は先頭引数に `FoodShip.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  在庫側の API(`FoodShip.Inventory.Client`)は DB のトランザクションの外で呼ぶ。
  """

  import Ecto.Query, warn: false

  alias FoodShip.Inventory.Client, as: InventoryClient
  alias FoodShip.Repo
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.Utils.Permission

  @doc """
  発送商品の一覧(商品コード順)。

  `"include_archived" => "true"` でアーカイブ済みも含める。
  """
  def list_shipping_items(params \\ %{}) do
    ShippingItem
    |> filter_archived(params)
    |> order_by([i], asc: i.item_code)
    |> Repo.all()
  end

  @doc "有効な発送商品すべて(選択肢用、商品コード順)。"
  def all_shipping_items, do: list_shipping_items()

  @doc "発送商品を取得する。"
  def get_shipping_item!(id), do: Repo.get!(ShippingItem, id)

  @doc "登録フォーム用の changeset。"
  def change_shipping_item(item, attrs \\ %{})

  def change_shipping_item(%ShippingItem{id: nil} = item, attrs),
    do: ShippingItem.create_changeset(item, attrs)

  def change_shipping_item(%ShippingItem{} = item, attrs),
    do: ShippingItem.update_changeset(item, attrs)

  @doc """
  商品コードから在庫側の商品を取得し、登録フォームの初期入力にする属性を返す。

  `{:ok, attrs}` / `{:error, :not_found}`(在庫側に無い・コードが空)/
  `{:error, :unauthorized}` / `{:error, :connection}`。
  """
  def fetch_inventory_item(item_code) when is_binary(item_code) do
    case String.trim(item_code) do
      "" ->
        {:error, :not_found}

      code ->
        with {:ok, item} <- InventoryClient.find_item(code), do: {:ok, inventory_attrs(item)}
    end
  end

  @doc "発送商品を登録する。在庫側の値は `fetch_inventory_item/1` で取得したものを渡す。"
  def create_shipping_item(scope, attrs) do
    with :ok <- authorize(scope) do
      %ShippingItem{} |> ShippingItem.create_changeset(attrs) |> Repo.insert()
    end
  end

  @doc "発送商品の換算(標準箱数・商品数量)を更新する。"
  def update_shipping_item(scope, %ShippingItem{} = item, attrs) do
    with :ok <- authorize(scope) do
      item |> ShippingItem.update_changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  在庫側の値(商品名・メーカー・商品コード)を取り直して更新する。

  商品コードで在庫側を検索し、`inventory_item_id` が一致しなければ `{:error, :mismatch}`。
  在庫側で商品コードが変わっていると `{:error, :not_found}` になる(アーカイブして登録し直す)。
  作成済みのトータルピックには影響しない(取得時点の値を持つため)。
  """
  def refresh_from_inventory(scope, %ShippingItem{} = item) do
    with :ok <- authorize(scope),
         {:ok, attrs} <- fetch_inventory_item(item.item_code),
         :ok <- check_same_item(item, attrs) do
      item |> ShippingItem.refresh_changeset(attrs) |> Repo.update()
    end
  end

  @doc "発送商品をアーカイブする。アーカイブ済みは新規伝票の選択肢に出ない。"
  def archive_shipping_item(scope, %ShippingItem{} = item) do
    with :ok <- authorize(scope) do
      item |> ShippingItem.archive_changeset() |> Repo.update()
    end
  end

  @doc "アーカイブ済みの発送商品を復帰する。"
  def restore_shipping_item(scope, %ShippingItem{} = item) do
    with :ok <- authorize(scope) do
      item |> ShippingItem.restore_changeset() |> Repo.update()
    end
  end

  defp inventory_attrs(item) do
    %{
      inventory_item_id: item.id,
      item_code: item.item_code,
      item_name: item.item_name,
      inventory_maker_id: item.maker_id,
      maker_name: item.maker_name
    }
  end

  defp check_same_item(%ShippingItem{inventory_item_id: id}, %{inventory_item_id: id}), do: :ok
  defp check_same_item(_item, _attrs), do: {:error, :mismatch}

  defp filter_archived(query, %{"include_archived" => "true"}), do: query
  defp filter_archived(query, _params), do: where(query, [i], is_nil(i.archived_at))

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
