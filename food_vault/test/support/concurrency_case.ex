defmodule FoodVault.ConcurrencyCase do
  @moduledoc """
  複数プロセスから同時に DB を更新するテスト用のケース。

  通常のテストは Sandbox のトランザクションの中で動くため、ロックの競合を再現できない。
  このケースは Sandbox の外(`sandbox: false`)で実コミットするので、テスト後に全テーブルを
  `TRUNCATE` して後始末する。`async: false` のモジュールでだけ使う(同期のテストは非同期の
  テストがすべて終わってから直列に走るため、他のテストのデータを消さない)。
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias FoodVault.Repo

  @tables ~w(inventory_transactions inventory_lots items makers warehouses users_tokens users)

  using do
    quote do
      import FoodVault.ConcurrencyCase, only: [concurrently: 2]
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")
    end)

    :ok
  end

  @doc """
  `fun` を `count` 個のプロセスで同時に実行し、結果のリストを返す。

  各プロセスは別の DB 接続を使う。全員が揃うまで待ってから一斉に開始する。
  """
  def concurrently(count, fun) when is_function(fun, 1) do
    pool_size = Repo.config()[:pool_size]

    if count > pool_size - 2 do
      raise ArgumentError, "count (#{count}) は pool_size (#{pool_size}) - 2 以下にしてください"
    end

    parent = self()

    tasks =
      for n <- 1..count do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          receive do
            :go -> fun.(n)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    for task <- tasks, do: send(task.pid, :go)

    Task.await_many(tasks, 30_000)
  end
end
