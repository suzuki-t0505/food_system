defmodule FoodShipWeb.Management.UserLive.IndexTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.AccountsFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.Accounts
  alias FoodShip.Accounts.User

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/management/users")
    end

    for role <- [:staff, :viewer] do
      test "#{role} は入れず、/ へ戻される", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: flash}}} =
                 conn |> log_in_user(user) |> live(~p"/management/users")

        assert flash["error"] == "権限がありません。"
      end
    end

    test "admin は一覧を見られる", %{conn: conn} do
      admin = admin_fixture()
      other = user_fixture(%{name: "別のユーザー"})
      {:ok, _lv, html} = conn |> log_in_user(admin) |> live(~p"/management/users")

      assert html =~ "ユーザー管理"
      assert html =~ admin.email
      assert html =~ other.email
    end
  end

  describe "ロール変更・アーカイブ・復帰" do
    setup %{conn: conn} do
      admin = admin_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "ロールを変更できる", %{conn: conn} do
      target = user_fixture(%{must_change_password: false})
      {:ok, lv, _html} = live(conn, ~p"/management/users")

      lv
      |> form("#role-form-#{target.id}", %{"role" => "staff"})
      |> render_change()

      assert Accounts.get_user!(target.id).role == :staff
      assert render(lv) =~ "ロールを変更しました。"
    end

    test "ロール変更でそのユーザーのセッションが失効する", %{conn: conn} do
      target = user_fixture(%{must_change_password: false})
      token = Accounts.generate_user_session_token(target)
      {:ok, lv, _html} = live(conn, ~p"/management/users")

      lv |> form("#role-form-#{target.id}", %{"role" => "admin"}) |> render_change()
      refute Accounts.get_user_by_session_token(token)
    end

    test "アーカイブして復帰できる", %{conn: conn} do
      target = user_fixture(%{must_change_password: false})
      token = Accounts.generate_user_session_token(target)
      {:ok, lv, _html} = live(conn, ~p"/management/users")

      html = lv |> element("#archive-#{target.id}") |> render_click()
      assert html =~ "ユーザーをアーカイブしました。"
      assert User.archived?(Accounts.get_user!(target.id))
      refute Accounts.get_user_by_session_token(token)

      html = lv |> element("#restore-#{target.id}") |> render_click()
      assert html =~ "ユーザーを復帰しました。"
      refute User.archived?(Accounts.get_user!(target.id))
    end

    test "自分自身の行にはアーカイブ・再設定の操作が出ない", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/management/users")
      refute has_element?(lv, "#archive-#{admin.id}")
      refute has_element?(lv, "#reset-password-#{admin.id}")
    end

    test "自分自身へのイベントをサーバーが拒否する(UI を迂回しても)", %{conn: conn, admin: admin} do
      other_admin = admin_fixture()
      {:ok, lv, _html} = live(conn, ~p"/management/users")

      html = render_click(lv, "archive", %{"id" => admin.id})
      assert html =~ "自分自身は変更できません。"
      refute User.archived?(Accounts.get_user!(admin.id))

      html = render_change(lv, "change_role", %{"user_id" => admin.id, "role" => "viewer"})
      assert html =~ "自分自身は変更できません。"
      assert Accounts.get_user!(admin.id).role == :admin

      # 他の admin は操作できる(有効な admin は 2 人)
      html = render_click(lv, "archive", %{"id" => other_admin.id})
      assert html =~ "ユーザーをアーカイブしました。"
    end

    test "不正なロール値は拒否する", %{conn: conn} do
      target = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/management/users")

      html = render_change(lv, "change_role", %{"user_id" => target.id, "role" => "superuser"})
      assert html =~ "ロールが正しくありません。"
      assert Accounts.get_user!(target.id).role == :viewer
    end
  end

  describe "イベント単位の権限検査" do
    test "開いた後に権限を失った場合も、handle_event 先頭の検査でサーバーが拒否する", %{conn: conn} do
      admin = admin_fixture()
      target = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/management/users")

      # mount 済みの current_scope を staff に書き換え、handle_event 先頭の Permission 検査を確認する
      :sys.replace_state(lv.pid, fn state ->
        socket = state.socket
        user = %{socket.assigns.current_scope.user | role: :staff}
        scope = %{socket.assigns.current_scope | user: user}
        %{state | socket: Phoenix.Component.assign(socket, :current_scope, scope)}
      end)

      html = render_click(lv, "archive", %{"id" => target.id})
      assert html =~ "権限がありません。"
      refute User.archived?(Accounts.get_user!(target.id))
    end
  end
end
