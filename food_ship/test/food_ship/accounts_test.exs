defmodule FoodShip.AccountsTest do
  use FoodShip.DataCase, async: true

  import FoodShip.AccountsFixtures

  alias FoodShip.Accounts
  alias FoodShip.Accounts.{User, UserToken}

  describe "get_user_by_email_and_password/2" do
    test "メールとパスワードが正しければユーザーを返す" do
      user = user_fixture()

      assert %User{id: id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      assert id == user.id
    end

    test "メールは大文字小文字を区別しない" do
      user = user_fixture()

      assert Accounts.get_user_by_email_and_password(
               String.upcase(user.email),
               valid_user_password()
             )
    end

    test "パスワード違い・存在しないメールは nil" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid password")
      refute Accounts.get_user_by_email_and_password("unknown@example.com", valid_user_password())
    end

    test "アーカイブ済みはログインできない" do
      user = archived_user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "create_user/2" do
    test "admin は登録でき、must_change_password は true になる" do
      scope = user_scope_fixture()
      attrs = valid_user_attributes(%{role: :staff})

      assert {:ok, user} = Accounts.create_user(scope, attrs)
      assert user.role == :staff
      assert user.must_change_password
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
    end

    test "staff / viewer / 未ログインは forbidden" do
      for role <- [:staff, :viewer] do
        scope = user_scope_fixture(user_fixture(%{role: role, must_change_password: false}))
        assert {:error, :forbidden} = Accounts.create_user(scope, valid_user_attributes())
      end

      assert {:error, :forbidden} = Accounts.create_user(nil, valid_user_attributes())
    end

    test "12 文字未満のパスワードは拒否する" do
      scope = user_scope_fixture()

      assert {:error, changeset} =
               Accounts.create_user(scope, valid_user_attributes(%{password: "short"}))

      assert %{password: [_]} = errors_on(changeset)
    end

    test "必須項目と形式を検証する" do
      scope = user_scope_fixture()

      assert {:error, changeset} =
               Accounts.create_user(scope, %{email: "not valid", name: "", password: ""})

      errors = errors_on(changeset)
      assert errors[:email]
      assert errors[:name]
      assert errors[:password]
    end

    test "メールの重複は大文字小文字を区別せず拒否する" do
      scope = user_scope_fixture()
      %{email: email} = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(scope, valid_user_attributes(%{email: String.upcase(email)}))

      assert "はすでに使われています。" in errors_on(changeset).email
    end

    test "アーカイブ済みユーザーのメールは再利用できない" do
      scope = user_scope_fixture()
      %{email: email} = archived_user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(scope, valid_user_attributes(%{email: email}))

      assert errors_on(changeset).email
    end

    test "パスワードを平文で保存・inspect しない" do
      user = user_fixture()
      refute inspect(user) =~ valid_user_password()
      refute inspect(user) =~ user.hashed_password
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "現在のパスワードが正しければ変更でき、must_change_password が false になる", %{user: user} do
      assert {:ok, {updated, _tokens}} =
               Accounts.update_user_password(user, %{
                 current_password: valid_user_password(),
                 password: "new valid password",
                 password_confirmation: "new valid password"
               })

      refute updated.must_change_password
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "現在のパスワード違い・確認不一致・12 文字未満・同一パスワードは拒否する", %{user: user} do
      attrs = %{password: "new valid password", password_confirmation: "new valid password"}

      assert {:error, cs} =
               Accounts.update_user_password(user, Map.put(attrs, :current_password, "wrong"))

      assert errors_on(cs).current_password

      assert {:error, cs} =
               Accounts.update_user_password(user, %{
                 current_password: valid_user_password(),
                 password: "new valid password",
                 password_confirmation: "different"
               })

      assert errors_on(cs).password_confirmation

      assert {:error, cs} =
               Accounts.update_user_password(user, %{
                 current_password: valid_user_password(),
                 password: "short",
                 password_confirmation: "short"
               })

      assert errors_on(cs).password

      assert {:error, cs} =
               Accounts.update_user_password(user, %{
                 current_password: valid_user_password(),
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert errors_on(cs).password
    end

    test "成功すると全トークンを削除する", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_user_session_token(user)

      assert {:ok, {_user, expired}} =
               Accounts.update_user_password(user, %{
                 current_password: valid_user_password(),
                 password: "new valid password",
                 password_confirmation: "new valid password"
               })

      assert length(expired) == 2
      refute Repo.exists?(UserToken.by_user_query(user.id))
    end
  end

  describe "セッショントークン" do
    setup do
      user = user_fixture()
      %{user: user, token: Accounts.generate_user_session_token(user)}
    end

    test "有効なトークンでユーザーを取得できる", %{user: user, token: token} do
      assert {%User{id: id}, %DateTime{}} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "不正なトークンは nil" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "14 日を過ぎたトークンは無効", %{token: token} do
      {1, nil} =
        Repo.update_all(UserToken,
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -15, :day)]
        )

      refute Accounts.get_user_by_session_token(token)
    end

    test "アーカイブ済みユーザーのトークンは無効", %{user: user, token: token} do
      user |> User.archive_changeset() |> Repo.update!()
      refute Accounts.get_user_by_session_token(token)
    end

    test "delete_user_session_token/1 でトークンを削除する", %{token: token} do
      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "update_user_role/3" do
    setup do
      %{scope: user_scope_fixture()}
    end

    test "他ユーザーのロールを変更し、全トークンを削除する", %{scope: scope} do
      target = user_fixture(%{role: :viewer})
      _ = Accounts.generate_user_session_token(target)

      assert {:ok, {user, expired}} = Accounts.update_user_role(scope, target, :staff)
      assert user.role == :staff
      assert length(expired) == 1
      refute Repo.exists?(UserToken.by_user_query(target.id))
    end

    test "自分自身は変更できない", %{scope: scope} do
      assert {:error, :self} = Accounts.update_user_role(scope, scope.user, :viewer)
      assert Accounts.get_user!(scope.user.id).role == :admin
    end

    test "staff は変更できない" do
      staff = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      target = user_fixture()
      assert {:error, :forbidden} = Accounts.update_user_role(staff, target, :admin)
      assert Accounts.get_user!(target.id).role == :viewer
    end

    test "最後の有効な admin の降格は、操作者の scope が古くても拒否される(DB を見て判定する)", %{scope: scope} do
      scope2 = user_scope_fixture(admin_fixture())

      # scope2 が scope.user を降格する。scope.user は admin でなくなる(scope は古いまま)
      assert {:ok, _} = Accounts.update_user_role(scope2, scope.user, :staff)

      # 有効な admin は scope2.user だけ。古い scope が降格しようとしても last_admin で拒否される
      assert {:error, :last_admin} = Accounts.update_user_role(scope, scope2.user, :viewer)
      assert Accounts.get_user!(scope2.user.id).role == :admin
    end
  end

  describe "archive_user/2 と restore_user/2" do
    setup do
      %{scope: user_scope_fixture()}
    end

    test "アーカイブすると全トークンを削除し、ログインできなくなる", %{scope: scope} do
      target = user_fixture()
      token = Accounts.generate_user_session_token(target)

      assert {:ok, {user, expired}} = Accounts.archive_user(scope, target)
      assert User.archived?(user)
      assert length(expired) == 1
      refute Accounts.get_user_by_session_token(token)
      refute Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end

    test "自分自身はアーカイブできない", %{scope: scope} do
      assert {:error, :self} = Accounts.archive_user(scope, scope.user)
      refute User.archived?(Accounts.get_user!(scope.user.id))
    end

    test "最後の有効な admin はアーカイブできない(別の admin が操作する場合は 2 人以上いる)" do
      scope = user_scope_fixture()
      other = admin_fixture()

      # 2 人いる間は片方をアーカイブできる
      assert {:ok, _} = Accounts.archive_user(scope, other)
      # 残り 1 人(scope.user)は自分自身なので :self
      assert {:error, :self} = Accounts.archive_user(scope, scope.user)
    end

    test "復帰すると archived_at が NULL に戻り、ログインできる", %{scope: scope} do
      target = archived_user_fixture()

      assert {:ok, user} = Accounts.restore_user(scope, target)
      refute User.archived?(user)
      assert Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end

    test "staff はアーカイブ・復帰できない" do
      staff = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Accounts.archive_user(staff, user_fixture())
      assert {:error, :forbidden} = Accounts.restore_user(staff, archived_user_fixture())
    end
  end

  describe "reset_user_password/3" do
    setup do
      %{scope: user_scope_fixture()}
    end

    test "再設定すると must_change_password が true になり、全トークンを削除する", %{scope: scope} do
      target = user_fixture(%{must_change_password: false})
      _ = Accounts.generate_user_session_token(target)

      assert {:ok, {user, expired}} =
               Accounts.reset_user_password(scope, target, %{password: "temporary password"})

      assert user.must_change_password
      assert length(expired) == 1
      assert Accounts.get_user_by_email_and_password(target.email, "temporary password")
      refute Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end

    test "12 文字未満は拒否し、トークンも残る", %{scope: scope} do
      target = user_fixture()
      _ = Accounts.generate_user_session_token(target)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.reset_user_password(scope, target, %{password: "short"})

      assert Repo.exists?(UserToken.by_user_query(target.id))
      assert Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end

    test "自分自身は再設定できない", %{scope: scope} do
      assert {:error, :self} =
               Accounts.reset_user_password(scope, scope.user, %{password: "temporary password"})
    end
  end

  describe "ensure_initial_admin/0" do
    setup do
      previous = Application.get_env(:food_ship, FoodShip.Accounts.InitialAdmin)

      on_exit(fn ->
        Application.put_env(:food_ship, FoodShip.Accounts.InitialAdmin, previous)
      end)

      :ok
    end

    test "設定が無ければ :not_configured" do
      Application.put_env(:food_ship, FoodShip.Accounts.InitialAdmin, [])
      assert {:error, :not_configured} = Accounts.ensure_initial_admin()
    end

    test "有効な admin がいなければ作成し、must_change_password は true" do
      Application.put_env(:food_ship, FoodShip.Accounts.InitialAdmin,
        email: "first@example.com",
        password: "initial password"
      )

      assert {:ok, %User{role: :admin, must_change_password: true}} =
               Accounts.ensure_initial_admin()

      assert Accounts.get_user_by_email_and_password("first@example.com", "initial password")
    end

    test "冪等: すでに有効な admin がいれば何もしない" do
      admin_fixture()

      Application.put_env(:food_ship, FoodShip.Accounts.InitialAdmin,
        email: "first@example.com",
        password: "initial password"
      )

      assert {:ok, :exists} = Accounts.ensure_initial_admin()
      refute Accounts.get_user_by_email_and_password("first@example.com", "initial password")
    end
  end
end
