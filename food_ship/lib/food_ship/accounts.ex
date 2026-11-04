defmodule FoodShip.Accounts do
  @moduledoc """
  認証・ユーザー管理。

  ユーザーは管理者が登録する(自己登録・マジックリンク・メール確認はない)。
  管理操作は先頭引数に `FoodShip.Accounts.Scope` を取り、`:manage_users` 権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  ## ルール

    * 有効な `admin` を常に 1 人以上残す(`{:error, :last_admin}`)
    * 自分自身のロール変更・アーカイブ・パスワード再設定は拒否する(`{:error, :self}`)
    * パスワード変更・ロール変更・アーカイブ・再設定では、そのユーザーの全トークンを
      同一トランザクションで削除する。戻り値の `expired_tokens` は、Web 層が
      `FoodShipWeb.UserAuth.disconnect_sessions/1` に渡して開いている LiveView を切断する
  """

  import Ecto.Query, warn: false

  alias FoodShip.Accounts.{Scope, User, UserToken}
  alias FoodShip.Repo
  alias FoodShip.Utils.Permission

  ## 認証

  @doc """
  メールとパスワードでユーザーを取得する。

  存在しない・パスワード不一致・アーカイブ済みはすべて `nil`(区別しない)。
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    if User.valid_password?(user, password) and not User.archived?(user), do: user
  end

  @doc "ユーザーを取得する。見つからなければ `Ecto.NoResultsError`。"
  def get_user!(id), do: Repo.get!(User, id)

  ## セッション

  @doc "セッショントークンを作って保存し、cookie / session に入れる値を返す。"
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  トークンからユーザーを取得する。有効なら `{user, token_inserted_at}`、無効なら `nil`。
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "セッショントークンを削除する(ログアウト)。"
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  ## 本人のパスワード変更

  @doc "本人のパスワード変更フォーム用の changeset。"
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  本人のパスワードを変更する。現在のパスワードが必要。

  成功すると `must_change_password` が false になり、全トークンを削除する。
  `{:ok, {user, expired_tokens}}` を返す。
  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## ユーザー管理(admin のみ)

  @doc "ユーザー一覧(アーカイブ済みを含む。登録順)。"
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.inserted_at, asc: u.id])
  end

  @doc "登録フォーム用の changeset。"
  def change_user_creation(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.create_changeset(user, attrs, opts)
  end

  @doc "パスワード再設定フォーム用の changeset。"
  def change_user_reset_password(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.reset_password_changeset(user, attrs, opts)
  end

  @doc "ユーザーを登録する。`must_change_password` は true になる。"
  def create_user(scope, attrs) do
    with :ok <- authorize(scope) do
      %User{}
      |> User.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "ロールを変更する。`{:ok, {user, expired_tokens}}`。"
  def update_user_role(scope, %User{} = user, role) do
    update_managed_user(scope, user, fn current, admins_left? ->
      if current.role == :admin and role != :admin and not admins_left? do
        {:error, :last_admin}
      else
        {:ok, User.role_changeset(current, %{role: role})}
      end
    end)
  end

  @doc "パスワードを再設定する。`must_change_password` は true になる。"
  def reset_user_password(scope, %User{} = user, attrs) do
    update_managed_user(scope, user, fn current, _admins_left? ->
      {:ok, User.reset_password_changeset(current, attrs)}
    end)
  end

  @doc "ユーザーをアーカイブする。"
  def archive_user(scope, %User{} = user) do
    update_managed_user(scope, user, fn current, admins_left? ->
      if current.role == :admin and not User.archived?(current) and not admins_left? do
        {:error, :last_admin}
      else
        {:ok, User.archive_changeset(current)}
      end
    end)
  end

  @doc "アーカイブからユーザーを復帰する。"
  def restore_user(scope, %User{} = user) do
    with :ok <- authorize(scope) do
      user |> User.restore_changeset() |> Repo.update()
    end
  end

  ## 初期管理者

  @doc """
  有効な `admin` がいなければ、設定された初期管理者を作る(冪等)。

  メールとパスワードは `config :food_ship, FoodShip.Accounts.InitialAdmin` から読む
  (`runtime.exs` が `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` を設定する)。
  作成したユーザーは `must_change_password = true`。

  `{:ok, user}`(作成)、`{:ok, :exists}`(すでにいる)、`{:error, :not_configured}`、
  `{:error, changeset}`。
  """
  def ensure_initial_admin do
    if Repo.exists?(from u in User, where: u.role == :admin and is_nil(u.archived_at)) do
      {:ok, :exists}
    else
      case initial_admin_config() do
        %{email: email, password: password} ->
          %User{}
          |> User.create_changeset(%{
            email: email,
            name: "管理者",
            role: :admin,
            password: password
          })
          |> Repo.insert()

        nil ->
          {:error, :not_configured}
      end
    end
  end

  defp initial_admin_config do
    config = Application.get_env(:food_ship, __MODULE__.InitialAdmin, [])

    with email when is_binary(email) and email != "" <- config[:email],
         password when is_binary(password) and password != "" <- config[:password] do
      %{email: email, password: password}
    else
      _ -> nil
    end
  end

  ## 内部

  defp authorize(scope) do
    if Permission.can?(scope_user(scope), :manage_users), do: :ok, else: {:error, :forbidden}
  end

  defp scope_user(%Scope{user: user}), do: user
  defp scope_user(_scope), do: nil

  defp ensure_not_self(%Scope{user: %User{id: id}}, %User{id: id}), do: {:error, :self}
  defp ensure_not_self(_scope, _user), do: :ok

  # 管理操作の共通処理。有効な admin をロックして数え(同時実行で 0 人にならないようにする)、
  # 最新の行に対して changeset を作り、更新と全トークン削除を同一トランザクションで行う。
  # `build` は `{:ok, changeset}` か `{:error, reason}` を返す。第 2 引数は、対象を除いても
  # 有効な admin が残るか。
  defp update_managed_user(scope, user, build) do
    with :ok <- authorize(scope),
         :ok <- ensure_not_self(scope, user) do
      Repo.transact(fn -> update_locked_user(user.id, build) end)
    end
  end

  defp update_locked_user(user_id, build) do
    active_admin_ids = lock_active_admin_ids()
    current = Repo.get!(User, user_id)
    admins_left? = Enum.any?(active_admin_ids, &(&1 != current.id))

    with {:ok, changeset} <- build.(current, admins_left?) do
      update_user_and_delete_all_tokens(changeset)
    end
  end

  defp lock_active_admin_ids do
    Repo.all(
      from u in User,
        where: u.role == :admin and is_nil(u.archived_at),
        lock: "FOR UPDATE",
        select: u.id
    )
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all(UserToken.by_user_query(user.id))

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
