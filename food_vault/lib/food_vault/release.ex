defmodule FoodVault.Release do
  @moduledoc """
  リリース時のタスク(`mix phx.gen.release` の生成物に初期管理者・シードを足したもの)。

      bin/migrate                                          # マイグレーションのみ
      bin/food_vault eval "FoodVault.Release.migrate_and_seed()"  # Cloud Run Job(マイグレーション → シード)
      bin/food_vault eval "FoodVault.Release.create_initial_admin()"
  """

  alias FoodVault.Accounts

  @app :food_vault

  @doc "全 Repo のマイグレーションを実行する。"
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "指定 Repo を `version` までロールバックする。"
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  マイグレーションのあと `priv/repo/seeds.exs` を実行する(Cloud Run Job 用)。

  シードは冪等(初期管理者・マスタともに、あれば作らない)なので、デプロイのたびに実行してよい。
  """
  @spec migrate_and_seed() :: :ok
  def migrate_and_seed do
    migrate()
    seeds = Application.app_dir(@app, "priv/repo/seeds.exs")
    {:ok, _, _} = Ecto.Migrator.with_repo(FoodVault.Repo, fn _repo -> Code.eval_file(seeds) end)
    :ok
  end

  @doc """
  初期管理者を作る。有効な `admin` がすでにいれば何もしない。

  `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` が未設定なら、その旨を出力して何も作らない。
  """
  @spec create_initial_admin() :: :ok | :error
  def create_initial_admin do
    load_app()
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
