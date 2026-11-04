defmodule FoodVault.MakersTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.Makers
  alias FoodVault.Makers.Maker

  describe "create_maker/2" do
    test "admin は登録できる" do
      assert {:ok, %Maker{maker_code: "M01", maker_name: "メーカーX"}} =
               Makers.create_maker(user_scope_fixture(), %{
                 "maker_code" => " M01 ",
                 "maker_name" => "メーカーX"
               })
    end

    test "必須項目が無ければ changeset エラー" do
      assert {:error, changeset} = Makers.create_maker(user_scope_fixture(), %{})

      assert %{maker_code: ["can't be blank"], maker_name: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "コードの重複は拒否する" do
      maker = maker_fixture()

      assert {:error, changeset} =
               Makers.create_maker(user_scope_fixture(), %{
                 maker_code: maker.maker_code,
                 maker_name: "別名"
               })

      assert %{maker_code: ["has already been taken"]} = errors_on(changeset)
    end

    for role <- [:staff, :viewer] do
      test "#{role} は拒否する" do
        scope =
          user_scope_fixture(user_fixture(%{role: unquote(role), must_change_password: false}))

        assert {:error, :forbidden} =
                 Makers.create_maker(scope, %{maker_code: "X", maker_name: "X"})
      end
    end
  end

  describe "update_maker/3" do
    test "名称を更新できる" do
      maker = maker_fixture()

      assert {:ok, %Maker{maker_name: "新名称"}} =
               Makers.update_maker(user_scope_fixture(), maker, %{maker_name: "新名称"})
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))

      assert {:error, :forbidden} =
               Makers.update_maker(scope, maker_fixture(), %{maker_name: "x"})
    end
  end

  describe "archive_maker/2 と restore_maker/2" do
    test "有効な商品が無ければアーカイブでき、復帰できる" do
      maker = maker_fixture()
      scope = user_scope_fixture()

      assert {:ok, archived} = Makers.archive_maker(scope, maker)
      assert Maker.archived?(archived)
      refute Enum.any?(Makers.all_makers(), &(&1.id == maker.id))

      assert {:ok, restored} = Makers.restore_maker(scope, archived)
      refute Maker.archived?(restored)
    end

    test "有効な商品があれば拒否する" do
      maker = maker_fixture()
      item_fixture(%{maker_id: maker.id})

      assert {:error, :has_active_items} = Makers.archive_maker(user_scope_fixture(), maker)
      refute Maker.archived?(Makers.get_maker!(maker.id))
    end

    test "商品がすべてアーカイブ済みならアーカイブできる" do
      maker = maker_fixture()
      item = item_fixture(%{maker_id: maker.id})
      scope = user_scope_fixture()
      {:ok, _} = FoodVault.Items.archive_item(scope, item)

      assert {:ok, _} = Makers.archive_maker(scope, maker)
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Makers.archive_maker(scope, maker_fixture())
    end
  end

  describe "list_makers/1" do
    test "既定ではアーカイブ済みを含めず、コード順に並ぶ" do
      m2 = maker_fixture(%{maker_code: "B-#{System.unique_integer([:positive])}"})
      m1 = maker_fixture(%{maker_code: "A-#{System.unique_integer([:positive])}"})
      gone = maker_fixture()
      {:ok, _} = Makers.archive_maker(user_scope_fixture(), gone)

      ids = Makers.list_makers(%{}).entries |> Enum.map(& &1.id)
      assert Enum.take(ids, 2) == [m1.id, m2.id]
      refute gone.id in ids

      all_ids = Makers.list_makers(%{"include_archived" => "true"}).entries |> Enum.map(& &1.id)
      assert gone.id in all_ids
    end
  end
end
