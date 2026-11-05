defmodule FoodShip.Clients do
  @moduledoc """
  発注元マスタ。

  書き込み関数は先頭引数に `FoodShip.Accounts.Scope` を取り、`:manage_masters` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。
  """

  import Ecto.Query, warn: false

  alias FoodShip.Clients.Client
  alias FoodShip.Repo
  alias FoodShip.Utils.Permission

  @doc """
  発注元の一覧(コード順)。

  `"include_archived" => "true"` でアーカイブ済みも含める。
  """
  def list_clients(params \\ %{}) do
    Client
    |> filter_archived(params)
    |> order_by([c], asc: c.client_code)
    |> Repo.all()
  end

  @doc "有効な発注元すべて(選択肢用、コード順)。"
  def all_clients, do: list_clients()

  @doc "発注元を取得する。"
  def get_client!(id), do: Repo.get!(Client, id)

  @doc "フォーム用の changeset。"
  def change_client(%Client{} = client, attrs \\ %{}), do: Client.changeset(client, attrs)

  @doc "発注元を登録する。"
  def create_client(scope, attrs) do
    with :ok <- authorize(scope) do
      %Client{} |> Client.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "発注元を更新する。"
  def update_client(scope, %Client{} = client, attrs) do
    with :ok <- authorize(scope) do
      client |> Client.changeset(attrs) |> Repo.update()
    end
  end

  @doc "発注元をアーカイブする。アーカイブ済みは新規伝票の選択肢に出ない。"
  def archive_client(scope, %Client{} = client) do
    with :ok <- authorize(scope) do
      client |> Client.archive_changeset() |> Repo.update()
    end
  end

  @doc "アーカイブ済みの発注元を復帰する。"
  def restore_client(scope, %Client{} = client) do
    with :ok <- authorize(scope) do
      client |> Client.restore_changeset() |> Repo.update()
    end
  end

  defp filter_archived(query, %{"include_archived" => "true"}), do: query
  defp filter_archived(query, _params), do: where(query, [c], is_nil(c.archived_at))

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_masters)
end
