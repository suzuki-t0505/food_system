defmodule FoodVaultWeb.Management.UserLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Accounts

  setup %{conn: conn} do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "アクセス制御" do
    for role <- [:staff, :viewer] do
      test "#{role} は登録・再設定画面に入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})
        target = user_fixture()
        conn = log_in_user(conn, user)

        assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/management/users/new")

        assert {:error, {:redirect, %{to: "/"}}} =
                 live(conn, ~p"/management/users/#{target.id}/reset_password")
      end
    end
  end

  describe "登録" do
    test "ユーザーを登録できる(初回ログインでパスワード変更が必要)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/management/users/new")
      email = unique_user_email()

      lv
      |> form("#user-form",
        user: %{name: "新人", email: email, role: "staff", password: "initial password"}
      )
      |> render_submit()

      assert_redirect(lv, ~p"/management/users")

      user = Accounts.get_user_by_email_and_password(email, "initial password")
      assert user.role == :staff
      assert user.must_change_password
    end

    test "12 文字未満・重複メールはエラーを表示する", %{conn: conn} do
      existing = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/management/users/new")

      html =
        lv
        |> form("#user-form",
          user: %{name: "新人", email: existing.email, role: "viewer", password: "short"}
        )
        |> render_submit()

      assert html =~ "12文字以上"
      assert html =~ "はすでに使われています。"
    end

    test "開いた後に admin でなくなっていたら保存できない", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/management/users/new")

      :sys.replace_state(lv.pid, fn state ->
        socket = state.socket
        user = %{socket.assigns.current_scope.user | role: :viewer}
        scope = %{socket.assigns.current_scope | user: user}
        %{state | socket: Phoenix.Component.assign(socket, :current_scope, scope)}
      end)

      email = unique_user_email()

      html =
        lv
        |> form("#user-form",
          user: %{name: "新人", email: email, role: "admin", password: "initial password"}
        )
        |> render_submit()

      assert html =~ "権限がありません。"
      refute Accounts.get_user_by_email_and_password(email, "initial password")
    end
  end

  describe "パスワード再設定" do
    test "再設定すると本人のセッションが失効し、強制変更になる", %{conn: conn} do
      target = user_fixture(%{must_change_password: false})
      token = Accounts.generate_user_session_token(target)
      {:ok, lv, html} = live(conn, ~p"/management/users/#{target.id}/reset_password")
      assert html =~ target.email

      lv |> form("#user-form", user: %{password: "temporary password"}) |> render_submit()
      assert_redirect(lv, ~p"/management/users")

      refute Accounts.get_user_by_session_token(token)
      user = Accounts.get_user_by_email_and_password(target.email, "temporary password")
      assert user.must_change_password
    end

    test "12 文字未満はエラー", %{conn: conn} do
      target = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/management/users/#{target.id}/reset_password")

      html = lv |> form("#user-form", user: %{password: "short"}) |> render_submit()
      assert html =~ "12文字以上"
      assert Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end

    test "自分自身の再設定は拒否する", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/management/users/#{admin.id}/reset_password")

      html = lv |> form("#user-form", user: %{password: "temporary password"}) |> render_submit()
      assert html =~ "自分自身のパスワードは"
      assert Accounts.get_user_by_email_and_password(admin.email, valid_user_password())
    end
  end
end
