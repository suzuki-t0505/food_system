defmodule FoodVault.Warehouses do
  @moduledoc """
  倉庫マスタ。

  書き込み関数は先頭引数に `FoodVault.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  アーカイブできるのは、全ロットが在庫 0 の倉庫だけ(`{:error, :has_stock}`)。
  在庫 0 のロットは引当済数も 0(CHECK 制約)なので、引当なしの条件も満たす。

  デフォルト倉庫(発送システムの引当先)は 0 件または 1 件。アーカイブ済みの倉庫はデフォルトに
  できず(`{:error, :archived}`)、デフォルトの倉庫はアーカイブできない(`{:error, :default_warehouse}`)。
  """

  import Ecto.Query, warn: false

  alias FoodVault.Inventories
  alias FoodVault.Repo
  alias FoodVault.Utils.Permission
  alias FoodVault.Warehouses.Warehouse

  @doc """
  倉庫の一覧(コード順、ページング)。

  `"include_archived" => "true"` でアーカイブ済みも含める。
  """
  def list_warehouses(params \\ %{}) do
    Warehouse
    |> filter_archived(params)
    |> order_by([w], asc: w.warehouse_code)
    |> Repo.paginate(params)
  end

  @doc "有効な倉庫すべて(選択肢用、コード順)。"
  def all_warehouses do
    Warehouse
    |> where([w], is_nil(w.archived_at))
    |> order_by([w], asc: w.warehouse_code)
    |> Repo.all()
  end

  @doc "倉庫を取得する。"
  def get_warehouse!(id), do: Repo.get!(Warehouse, id)

  @doc "デフォルト倉庫。未設定なら `nil`。"
  def get_default_warehouse do
    Warehouse
    |> where([w], w.is_default and is_nil(w.archived_at))
    |> Repo.one()
  end

  @doc """
  倉庫をデフォルトにする。現在のデフォルトは外れる(常に 0 件または 1 件)。

  アーカイブ済みなら `{:error, :archived}`。すでにデフォルトなら何もせず `{:ok, warehouse}`。
  """
  def set_default_warehouse(scope, %Warehouse{} = warehouse) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_set_default(warehouse.id) end)
  end

  defp do_set_default(warehouse_id) do
    warehouse = lock_warehouse(warehouse_id)

    cond do
      Warehouse.archived?(warehouse) ->
        {:error, :archived}

      Warehouse.default?(warehouse) ->
        {:ok, warehouse}

      true ->
        # 部分ユニークインデックスがあるので、先に今のデフォルトを外してから設定する
        Warehouse |> where([w], w.is_default) |> Repo.update_all(set: [is_default: false])
        warehouse |> Warehouse.default_changeset() |> Repo.update()
    end
  end

  @doc "フォーム用の changeset。"
  def change_warehouse(%Warehouse{} = warehouse, attrs \\ %{}),
    do: Warehouse.changeset(warehouse, attrs)

  @doc "倉庫を登録する。"
  def create_warehouse(scope, attrs) do
    with :ok <- authorize(scope) do
      %Warehouse{} |> Warehouse.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "倉庫を更新する。"
  def update_warehouse(scope, %Warehouse{} = warehouse, attrs) do
    with :ok <- authorize(scope) do
      warehouse |> Warehouse.changeset(attrs) |> Repo.update()
    end
  end

  @doc "倉庫をアーカイブする。デフォルトなら `{:error, :default_warehouse}`、在庫があれば `{:error, :has_stock}`。"
  def archive_warehouse(scope, %Warehouse{} = warehouse) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_archive(warehouse.id) end)
  end

  defp do_archive(warehouse_id) do
    warehouse = lock_warehouse(warehouse_id)

    cond do
      Warehouse.archived?(warehouse) -> {:ok, warehouse}
      Warehouse.default?(warehouse) -> {:error, :default_warehouse}
      Inventories.warehouse_has_stock?(warehouse.id) -> {:error, :has_stock}
      true -> warehouse |> Warehouse.archive_changeset() |> Repo.update()
    end
  end

  @doc "アーカイブ済みの倉庫を復帰する。"
  def restore_warehouse(scope, %Warehouse{} = warehouse) do
    with :ok <- authorize(scope) do
      warehouse |> Warehouse.restore_changeset() |> Repo.update()
    end
  end

  @doc """
  入荷・引当・移動先作成で使う。倉庫を `FOR SHARE` で読み、アーカイブ済みなら `nil`。

  アーカイブ処理(`FOR UPDATE`)との競合で、アーカイブ済みの倉庫に在庫が入らないようにする。
  """
  def lock_active_warehouse_for_share(warehouse_id) do
    Warehouse
    |> where([w], w.id == ^warehouse_id and is_nil(w.archived_at))
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  defp lock_warehouse(id) do
    Warehouse |> where([w], w.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()
  end

  defp filter_archived(query, %{"include_archived" => "true"}), do: query
  defp filter_archived(query, _params), do: where(query, [w], is_nil(w.archived_at))

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
