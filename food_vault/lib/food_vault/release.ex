defmodule FoodVault.Release do
  @moduledoc """
  リリース時のタスク。本番イメージへの組み込みは別途(architecture §16 #3)。

      bin/food_vault eval "FoodVault.Release.create_initial_admin()"
  """

  alias FoodVault.Accounts

  @doc """
  初期管理者を作る。有効な `admin` がすでにいれば何もしない。

  `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` が未設定なら、その旨を出力して何も作らない。
  """
  @spec create_initial_admin() :: :ok | :error
  def create_initial_admin do
    {:ok, result, _apps} = Ecto.Migrator.with_repo(FoodVault.Repo, fn _repo -> run() end)
    result
  end

  @doc "実行中の Repo に対して初期管理者を作る(seeds・開発用)。"
  @spec run() :: :ok | :error
  def run do
    case Accounts.ensure_initial_admin() do
      {:ok, :exists} ->
        IO.puts("有効な管理者がいるため、初期管理者は作成しません。")
        :ok

      {:ok, user} ->
        IO.puts("初期管理者を作成しました: #{user.email}(初回ログイン時にパスワード変更が必要です)")
        :ok

      {:error, :not_configured} ->
        IO.puts("INITIAL_ADMIN_EMAIL / INITIAL_ADMIN_PASSWORD が設定されていません。")
        :error

      {:error, %Ecto.Changeset{} = changeset} ->
        IO.puts("初期管理者を作成できません: #{inspect(changeset.errors)}")
        :error
    end
  end
end
