defmodule FoodVault.Makers do
  @moduledoc """
  メーカーマスタ。

  書き込み関数は先頭引数に `FoodVault.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  アーカイブできるのは、有効な商品を持たないメーカーだけ(`{:error, :has_active_items}`)。
  """

  import Ecto.Query, warn: false

  alias FoodVault.Items.Item
  alias FoodVault.Makers.Maker
  alias FoodVault.Repo
  alias FoodVault.Utils.Permission

  @doc """
  メーカーの一覧(コード順、ページング)。

  `"include_archived" => "true"` でアーカイブ済みも含める。
  """
  def list_makers(params \\ %{}) do
    Maker
    |> filter_archived(params)
    |> order_by([m], asc: m.maker_code)
    |> Repo.paginate(params)
  end

  @doc "有効なメーカーすべて(選択肢用、コード順)。"
  def all_makers do
    Maker |> where([m], is_nil(m.archived_at)) |> order_by([m], asc: m.maker_code) |> Repo.all()
  end

  @doc "メーカーを取得する。"
  def get_maker!(id), do: Repo.get!(Maker, id)

  @doc "フォーム用の changeset。"
  def change_maker(%Maker{} = maker, attrs \\ %{}), do: Maker.changeset(maker, attrs)

  @doc "メーカーを登録する。"
  def create_maker(scope, attrs) do
    with :ok <- authorize(scope) do
      %Maker{} |> Maker.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "メーカーを更新する。"
  def update_maker(scope, %Maker{} = maker, attrs) do
    with :ok <- authorize(scope) do
      maker |> Maker.changeset(attrs) |> Repo.update()
    end
  end

  @doc "メーカーをアーカイブする。有効な商品があれば `{:error, :has_active_items}`。"
  def archive_maker(scope, %Maker{} = maker) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_archive(maker.id) end)
  end

  defp do_archive(maker_id) do
    maker = lock_maker(maker_id)

    cond do
      Maker.archived?(maker) -> {:ok, maker}
      active_items?(maker.id) -> {:error, :has_active_items}
      true -> maker |> Maker.archive_changeset() |> Repo.update()
    end
  end

  @doc "アーカイブ済みのメーカーを復帰する。"
  def restore_maker(scope, %Maker{} = maker) do
    with :ok <- authorize(scope) do
      maker |> Maker.restore_changeset() |> Repo.update()
    end
  end

  @doc """
  商品の登録・復帰時に使う。メーカーを `FOR SHARE` で読み、アーカイブ済みなら `nil`。

  アーカイブ処理(`FOR UPDATE`)との競合で、アーカイブ済みメーカーに商品が付かないようにする。
  """
  def lock_active_maker_for_share(maker_id) do
    Maker
    |> where([m], m.id == ^maker_id and is_nil(m.archived_at))
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  defp lock_maker(id), do: Maker |> where([m], m.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()

  defp active_items?(maker_id) do
    Item |> where([i], i.maker_id == ^maker_id and is_nil(i.archived_at)) |> Repo.exists?()
  end

  defp filter_archived(query, %{"include_archived" => "true"}), do: query
  defp filter_archived(query, _params), do: where(query, [m], is_nil(m.archived_at))

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
