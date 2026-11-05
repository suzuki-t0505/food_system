defmodule FoodVault.Items do
  @moduledoc """
  商品マスタ。

  書き込み関数は先頭引数に `FoodVault.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  ## ルール

    * ロット(在庫 0 を含む)がある商品は、`units_per_case` と `expiration_type` を変更できない
      (`{:error, :lots_exist}`)。商品行を `FOR UPDATE` で読んでから検査する。入荷・引当は
      商品行を `FOR SHARE` で読むため、同時に走っても検査をすり抜けない
    * アーカイブできるのは、全ロットが在庫 0 の商品だけ(`{:error, :has_stock}`)。在庫 0 の
      ロットは引当済数も 0(CHECK 制約)なので、`allocated` なオーダー明細には含まれない
    * アーカイブ済みのメーカーには商品を登録・復帰できない
  """

  import Ecto.Query, warn: false

  alias FoodVault.Inventories
  alias FoodVault.Items.Item
  alias FoodVault.Makers
  alias FoodVault.Repo
  alias FoodVault.Utils.Permission

  @doc """
  商品の一覧(コード順、ページング、メーカーを preload)。

  `"include_archived" => "true"` でアーカイブ済みも含める。
  """
  def list_items(params \\ %{}) do
    Item
    |> filter_archived(params)
    |> order_by([i], asc: i.item_code)
    |> preload(:maker)
    |> Repo.paginate(params)
  end

  @doc "有効な商品すべて(選択肢用、コード順、メーカーを preload)。"
  def all_items, do: Repo.all(active_items_query())

  defp active_items_query do
    Item
    |> where([i], is_nil(i.archived_at))
    |> order_by([i], asc: i.item_code)
    |> preload(:maker)
  end

  @doc """
  有効な商品を商品コードで検索する(在庫 API ⑦ 用。コード順、メーカーを preload)。

  `item_code` が `nil`・空(空白のみ)なら有効な商品すべて。指定時は**完全一致**。
  """
  def search_active_items(item_code \\ nil)

  def search_active_items(item_code) when is_binary(item_code) do
    case String.trim(item_code) do
      "" -> all_items()
      code -> active_items_query() |> where([i], i.item_code == ^code) |> Repo.all()
    end
  end

  def search_active_items(_item_code), do: all_items()

  @doc "商品を取得する(メーカーを preload)。"
  def get_item!(id), do: Item |> preload(:maker) |> Repo.get!(id)

  @doc "フォーム用の changeset。"
  def change_item(%Item{} = item, attrs \\ %{}), do: Item.changeset(item, attrs)

  @doc "商品を登録する。アーカイブ済みのメーカーは `maker_id` のエラーになる。"
  def create_item(scope, attrs) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_create(attrs) end)
  end

  defp do_create(attrs) do
    case %Item{} |> Item.changeset(attrs) |> ensure_active_maker() do
      %Ecto.Changeset{valid?: true} = changeset -> Repo.insert(changeset)
      changeset -> {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  商品を更新する。ロットがあるのに入数・期限区分を変えると `{:error, :lots_exist}`。
  """
  def update_item(scope, %Item{} = item, attrs) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_update(item.id, attrs) end)
  end

  defp do_update(item_id, attrs) do
    item = lock_item(item_id)
    changeset = Item.changeset(item, attrs)

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :update}}

      Item.locked_fields_changed?(changeset) and Inventories.item_has_lots?(item.id) ->
        {:error, :lots_exist}

      true ->
        changeset |> ensure_active_maker() |> update_if_valid()
    end
  end

  @doc "商品をアーカイブする。在庫があれば `{:error, :has_stock}`。"
  def archive_item(scope, %Item{} = item) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_archive(item.id) end)
  end

  defp do_archive(item_id) do
    item = lock_item(item_id)

    cond do
      Item.archived?(item) -> {:ok, item}
      Inventories.item_has_stock?(item.id) -> {:error, :has_stock}
      true -> item |> Item.archive_changeset() |> Repo.update()
    end
  end

  @doc "アーカイブ済みの商品を復帰する。メーカーがアーカイブ済みなら `{:error, :archived_maker}`。"
  def restore_item(scope, %Item{} = item) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_restore(item.id) end)
  end

  defp do_restore(item_id) do
    item = lock_item(item_id)

    if Makers.lock_active_maker_for_share(item.maker_id) do
      item |> Item.restore_changeset() |> Repo.update()
    else
      {:error, :archived_maker}
    end
  end

  @doc """
  入荷・引当で使う。商品を `FOR SHARE` で読む(アーカイブ済みは `nil`)。

  マスタ更新(`FOR UPDATE`)と競合しないよう、ロットの作成・更新の前に必ず呼ぶ。
  """
  def lock_active_items_for_share(item_ids) do
    Item
    |> where([i], i.id in ^item_ids and is_nil(i.archived_at))
    |> order_by([i], asc: i.id)
    |> lock("FOR SHARE")
    |> Repo.all()
  end

  defp lock_item(id), do: Item |> where([i], i.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()

  # メーカーが指定され、変更されたときだけ、有効なメーカーであることを確認する
  defp ensure_active_maker(%Ecto.Changeset{changes: %{maker_id: maker_id}} = changeset) do
    if Makers.lock_active_maker_for_share(maker_id) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :maker_id, "は有効なメーカーを選択してください")
    end
  end

  defp ensure_active_maker(changeset), do: changeset

  defp update_if_valid(%Ecto.Changeset{valid?: true} = changeset), do: Repo.update(changeset)
  defp update_if_valid(changeset), do: {:error, %{changeset | action: :update}}

  defp filter_archived(query, %{"include_archived" => "true"}), do: query
  defp filter_archived(query, _params), do: where(query, [i], is_nil(i.archived_at))

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
