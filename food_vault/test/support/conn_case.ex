defmodule FoodVaultWeb.ConnCase do
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
  by setting `use FoodVaultWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FoodVaultWeb.Endpoint

      use FoodVaultWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FoodVaultWeb.ConnCase
    end
  end

  setup tags do
    FoodVault.DataCase.setup_sandbox(tags)
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
    user = FoodVault.AccountsFixtures.user_fixture(%{role: role, must_change_password: false})
    scope = FoodVault.Accounts.Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc "`user` のセッションを作った `conn` を返す。"
  def log_in_user(conn, user) do
    token = FoodVault.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
