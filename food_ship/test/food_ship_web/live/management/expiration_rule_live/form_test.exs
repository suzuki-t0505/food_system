defmodule FoodShipWeb.Management.ExpirationRuleLive.FormTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.{Clients, ExpirationRules}

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, ~p"/management/expiration_rules/new")
    end

    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/expiration_rules/new")
      end
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "登録できる", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/expiration_rules/new")

      lv
      |> form("#expiration-rule-form",
        expiration_rule: %{
          client_id: client.id,
          shipping_item_id: item.id,
          min_remaining_days: "30"
        }
      )
      |> render_submit()

      assert_redirect(lv, ~p"/masters/expiration_rules")
      assert %{min_remaining_days: 30} = ExpirationRules.get_rule(client.id, item.id)
    end

    test "アーカイブ済みの発注元は選択肢に出ない", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "休止発注元"})
      {:ok, _} = Clients.archive_client(scope, client)

      {:ok, _lv, html} = live(conn, ~p"/management/expiration_rules/new")
      refute html =~ "休止発注元"
    end

    test "必須項目が空ならエラーを表示して保存しない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/expiration_rules/new")

      html =
        lv
        |> form("#expiration-rule-form", expiration_rule: %{min_remaining_days: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert ExpirationRules.list_expiration_rules() == []
    end

    test "同じ組み合わせの重複はエラー", %{conn: conn} do
      rule = expiration_rule_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/expiration_rules/new")

      html =
        lv
        |> form("#expiration-rule-form",
          expiration_rule: %{
            client_id: rule.client_id,
            shipping_item_id: rule.shipping_item_id,
            min_remaining_days: "10"
          }
        )
        |> render_submit()

      assert html =~ "この発注元ですでに登録されています。"
    end

    test "編集は最低残日数だけ", %{conn: conn} do
      client = client_fixture(%{client_name: "編集発注元"})
      rule = expiration_rule_fixture(%{client_id: client.id, min_remaining_days: 30})
      {:ok, lv, html} = live(conn, ~p"/management/expiration_rules/#{rule.id}/edit")

      assert html =~ "編集発注元"
      refute has_element?(lv, "select")

      lv
      |> form("#expiration-rule-form", expiration_rule: %{min_remaining_days: "90"})
      |> render_submit()

      assert_redirect(lv, ~p"/masters/expiration_rules")
      assert ExpirationRules.get_expiration_rule!(rule.id).min_remaining_days == 90
    end
  end
end
