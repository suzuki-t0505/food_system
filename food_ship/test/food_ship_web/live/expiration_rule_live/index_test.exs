defmodule FoodShipWeb.ExpirationRuleLive.IndexTest do
  use FoodShipWeb.ConnCase, async: true

  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.ExpirationRules

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(conn, ~p"/masters/expiration_rules")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、編集・削除ボタンは出ない", %{conn: conn} do
      client = client_fixture(%{client_name: "閲覧発注元"})
      rule = expiration_rule_fixture(%{client_id: client.id, min_remaining_days: 45})
      {:ok, lv, html} = live(conn, ~p"/masters/expiration_rules")

      assert html =~ "閲覧発注元"
      assert html =~ "45 日"
      refute has_element?(lv, "#new-expiration-rule")
      refute has_element?(lv, "#edit-expiration-rule-#{rule.id}")
      refute has_element?(lv, "#delete-expiration-rule-#{rule.id}")
    end

    test "イベントを直接送っても削除できない", %{conn: conn} do
      rule = expiration_rule_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/expiration_rules")

      assert render_click(lv, "delete", %{"id" => rule.id}) =~ "権限がありません。"
      assert ExpirationRules.get_rule(rule.client_id, rule.shipping_item_id)
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "削除できる", %{conn: conn} do
      rule = expiration_rule_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/expiration_rules")

      lv |> element("#delete-expiration-rule-#{rule.id}") |> render_click()

      refute has_element?(lv, "#expiration-rule-#{rule.id}")
      assert ExpirationRules.get_rule(rule.client_id, rule.shipping_item_id) == nil
    end
  end
end
