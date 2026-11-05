defmodule FoodShipWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FoodShipWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FoodShipWeb.Endpoint

      use FoodShipWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FoodShipWeb.ConnCase
    end
  end

  setup tags do
    FoodShip.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  ログイン済みのユーザーを用意する setup。

      setup :register_and_log_in_user          # viewer
      @tag role: :admin
      setup :register_and_log_in_user

  `must_change_password` は false(パスワード変更済み)にする。
  `conn` / `user` / `scope` をテストコンテキストに入れる。
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    role = Map.get(context, :role, :viewer)
    user = FoodShip.AccountsFixtures.user_fixture(%{role: role, must_change_password: false})
    scope = FoodShip.Accounts.Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc """
  `Task` ＋ `handle_info` の結果を待つ。`fun` が失敗(`ExUnit.AssertionError`)しなくなるまで、
  `timeout` ミリ秒まで 10 ミリ秒間隔で再実行する。
  """
  def wait_until(fun, timeout \\ 2000) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if timeout <= 0 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        wait_until(fun, timeout - 10)
      end
  end

  @doc "`user` のセッションを作った `conn` を返す。"
  def log_in_user(conn, user) do
    token = FoodShip.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
