defmodule FoodShip.ExpirationRulesTest do
  use FoodShip.DataCase, async: true

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures

  alias FoodShip.{Clients, ExpirationRules, ShippingItems}

  describe "create_expiration_rule/2" do
    test "admin は登録できる" do
      client = client_fixture()
      item = shipping_item_fixture()

      assert {:ok, rule} =
               ExpirationRules.create_expiration_rule(user_scope_fixture(), %{
                 client_id: client.id,
                 shipping_item_id: item.id,
                 min_remaining_days: 45
               })

      assert rule.min_remaining_days == 45
    end

    test "必須項目が無ければ changeset エラー" do
      assert {:error, changeset} =
               ExpirationRules.create_expiration_rule(user_scope_fixture(), %{})

      assert %{
               client_id: ["can't be blank"],
               shipping_item_id: ["can't be blank"],
               min_remaining_days: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "最低残日数は 0 以上(0 は許可、負数は拒否)" do
      client = client_fixture()
      item = shipping_item_fixture()
      attrs = %{client_id: client.id, shipping_item_id: item.id}

      assert {:ok, _} =
               ExpirationRules.create_expiration_rule(
                 user_scope_fixture(),
                 Map.put(attrs, :min_remaining_days, 0)
               )

      other = shipping_item_fixture()

      assert {:error, changeset} =
               ExpirationRules.create_expiration_rule(user_scope_fixture(), %{
                 client_id: client.id,
                 shipping_item_id: other.id,
                 min_remaining_days: -1
               })

      assert %{min_remaining_days: [_]} = errors_on(changeset)
    end

    test "同じ発注元 × 発送商品は重複登録できない" do
      rule = expiration_rule_fixture()

      assert {:error, changeset} =
               ExpirationRules.create_expiration_rule(user_scope_fixture(), %{
                 client_id: rule.client_id,
                 shipping_item_id: rule.shipping_item_id,
                 min_remaining_days: 10
               })

      assert %{shipping_item_id: ["は、この発注元ですでに登録されています。"]} = errors_on(changeset)
    end

    test "アーカイブ済みの発注元・発送商品は選べない" do
      scope = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture()
      {:ok, _} = Clients.archive_client(scope, client)
      {:ok, _} = ShippingItems.archive_shipping_item(scope, item)

      assert {:error, changeset} =
               ExpirationRules.create_expiration_rule(scope, %{
                 client_id: client.id,
                 shipping_item_id: item.id,
                 min_remaining_days: 30
               })

      assert %{client_id: ["は選べません。"], shipping_item_id: ["は選べません。"]} =
               errors_on(changeset)

      assert ExpirationRules.list_expiration_rules() == []
    end

    for role <- [:staff, :viewer] do
      test "#{role} は拒否する" do
        scope =
          user_scope_fixture(user_fixture(%{role: unquote(role), must_change_password: false}))

        client = client_fixture()
        item = shipping_item_fixture()

        assert {:error, :forbidden} =
                 ExpirationRules.create_expiration_rule(scope, %{
                   client_id: client.id,
                   shipping_item_id: item.id,
                   min_remaining_days: 30
                 })

        assert ExpirationRules.list_expiration_rules() == []
      end
    end
  end

  describe "update_expiration_rule/3" do
    test "最低残日数だけ更新でき、発注元・商品は変わらない" do
      rule = expiration_rule_fixture()
      other_client = client_fixture()

      assert {:ok, updated} =
               ExpirationRules.update_expiration_rule(user_scope_fixture(), rule, %{
                 min_remaining_days: 60,
                 client_id: other_client.id
               })

      assert updated.min_remaining_days == 60
      assert updated.client_id == rule.client_id
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      rule = expiration_rule_fixture(%{min_remaining_days: 30})

      assert {:error, :forbidden} =
               ExpirationRules.update_expiration_rule(scope, rule, %{min_remaining_days: 1})

      assert ExpirationRules.get_expiration_rule!(rule.id).min_remaining_days == 30
    end
  end

  describe "delete_expiration_rule/2" do
    test "admin は削除できる(物理削除)" do
      rule = expiration_rule_fixture()

      assert {:ok, _} = ExpirationRules.delete_expiration_rule(user_scope_fixture(), rule)
      assert ExpirationRules.get_rule(rule.client_id, rule.shipping_item_id) == nil
    end

    test "staff は拒否し、残る" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      rule = expiration_rule_fixture()

      assert {:error, :forbidden} = ExpirationRules.delete_expiration_rule(scope, rule)
      assert ExpirationRules.get_rule(rule.client_id, rule.shipping_item_id)
    end
  end

  describe "get_rule/2 と list_expiration_rules/0" do
    test "ルールが無ければ nil(制限なし)" do
      assert ExpirationRules.get_rule(Ecto.ULID.generate(), Ecto.ULID.generate()) == nil
    end

    test "一覧は発注元コード・商品コード順で、発注元と商品を preload する" do
      client_b = client_fixture(%{client_code: "B"})
      client_a = client_fixture(%{client_code: "A"})
      item = shipping_item_fixture()

      expiration_rule_fixture(%{client_id: client_b.id, shipping_item_id: item.id})
      expiration_rule_fixture(%{client_id: client_a.id, shipping_item_id: item.id})

      assert ["A", "B"] =
               Enum.map(ExpirationRules.list_expiration_rules(), & &1.client.client_code)
    end
  end
end
