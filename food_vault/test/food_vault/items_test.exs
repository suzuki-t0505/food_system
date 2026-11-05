defmodule FoodVault.ItemsTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Items, Makers}
  alias FoodVault.Items.Item

  defp valid_attrs(maker, extra \\ %{}) do
    Map.merge(
      %{
        maker_id: maker.id,
        item_code: unique_code("I"),
        item_name: "商品A",
        units_per_case: 12,
        expiration_type: :best_before
      },
      extra
    )
  end

  describe "create_item/2" do
    test "admin は登録できる" do
      maker = maker_fixture()

      assert {:ok, %Item{units_per_case: 12, expiration_type: :best_before}} =
               Items.create_item(user_scope_fixture(), valid_attrs(maker))
    end

    test "入数は 1 以上、期限区分は定義済みの値のみ" do
      maker = maker_fixture()

      assert {:error, cs} =
               Items.create_item(user_scope_fixture(), valid_attrs(maker, %{units_per_case: 0}))

      assert %{units_per_case: [_]} = errors_on(cs)

      assert {:error, cs} =
               Items.create_item(
                 user_scope_fixture(),
                 valid_attrs(maker, %{expiration_type: "unknown"})
               )

      assert %{expiration_type: [_]} = errors_on(cs)
    end

    test "商品コードの重複は拒否する" do
      maker = maker_fixture()
      item = item_fixture(%{maker_id: maker.id})

      assert {:error, cs} =
               Items.create_item(
                 user_scope_fixture(),
                 valid_attrs(maker, %{item_code: item.item_code})
               )

      assert %{item_code: ["has already been taken"]} = errors_on(cs)
    end

    test "アーカイブ済みのメーカーは選べない" do
      maker = maker_fixture()
      {:ok, _} = Makers.archive_maker(user_scope_fixture(), maker)

      assert {:error, cs} = Items.create_item(user_scope_fixture(), valid_attrs(maker))
      assert %{maker_id: [_]} = errors_on(cs)
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Items.create_item(scope, valid_attrs(maker_fixture()))
    end
  end

  describe "update_item/3" do
    test "ロットが無ければ入数・期限区分を変更できる" do
      item = item_fixture()

      assert {:ok, %Item{units_per_case: 24, expiration_type: :none}} =
               Items.update_item(user_scope_fixture(), item, %{
                 units_per_case: 24,
                 expiration_type: :none
               })
    end

    test "ロットがあれば入数・期限区分の変更を拒否する(在庫 0 のロットでも)" do
      item = item_fixture()
      empty_lot!(item)
      scope = user_scope_fixture()

      assert {:error, :lots_exist} = Items.update_item(scope, item, %{units_per_case: 24})
      assert {:error, :lots_exist} = Items.update_item(scope, item, %{expiration_type: :none})
      assert Items.get_item!(item.id).units_per_case == 12
    end

    test "ロットがあっても名称・メーカーは変更できる" do
      item = item_fixture()
      lot_fixture(%{item_id: item.id, case_qty: 3})
      new_maker = maker_fixture()

      assert {:ok, %Item{item_name: "新名称", maker_id: maker_id}} =
               Items.update_item(user_scope_fixture(), item, %{
                 item_name: "新名称",
                 maker_id: new_maker.id,
                 units_per_case: 12
               })

      assert maker_id == new_maker.id
    end

    test "入力エラーは changeset" do
      assert {:error, %Ecto.Changeset{}} =
               Items.update_item(user_scope_fixture(), item_fixture(), %{item_name: ""})
    end
  end

  describe "archive_item/2 と restore_item/2" do
    test "在庫が無ければアーカイブでき、復帰できる" do
      item = item_fixture()
      scope = user_scope_fixture()

      assert {:ok, archived} = Items.archive_item(scope, item)
      assert Item.archived?(archived)
      refute Enum.any?(Items.all_items(), &(&1.id == item.id))

      assert {:ok, restored} = Items.restore_item(scope, archived)
      refute Item.archived?(restored)
    end

    test "在庫があれば拒否し、在庫 0 のロットだけなら許可する" do
      scope = user_scope_fixture()
      with_stock = item_fixture()
      lot_fixture(%{item_id: with_stock.id, case_qty: 0, piece_qty: 1})
      empty = item_fixture()
      empty_lot!(empty)

      assert {:error, :has_stock} = Items.archive_item(scope, with_stock)
      assert {:ok, _} = Items.archive_item(scope, empty)
    end

    test "メーカーがアーカイブ済みなら復帰できない" do
      scope = user_scope_fixture()
      maker = maker_fixture()
      item = item_fixture(%{maker_id: maker.id})
      {:ok, archived} = Items.archive_item(scope, item)
      {:ok, _} = Makers.archive_maker(scope, maker)

      assert {:error, :archived_maker} = Items.restore_item(scope, archived)
    end

    test "staff は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:error, :forbidden} = Items.archive_item(scope, item_fixture())
    end
  end

  describe "lock_active_items_for_share/1" do
    test "有効な商品だけを返す" do
      scope = user_scope_fixture()
      active = item_fixture()
      archived = item_fixture()
      {:ok, _} = Items.archive_item(scope, archived)

      ids = Items.lock_active_items_for_share([active.id, archived.id]) |> Enum.map(& &1.id)
      assert ids == [active.id]
    end
  end

  describe "search_active_items/1" do
    test "商品コードの完全一致、空・nil は有効な商品すべて、アーカイブ済みは除く" do
      item = item_fixture(%{item_code: "SEARCH-1"})
      other = item_fixture(%{item_code: "SEARCH-2"})
      archived = item_fixture(%{item_code: "SEARCH-3"})
      {:ok, _} = Items.archive_item(user_scope_fixture(), archived)

      assert [%{id: id, maker: %{}}] = Items.search_active_items("SEARCH-1")
      assert id == item.id
      assert Items.search_active_items(" SEARCH-1 ") |> Enum.map(& &1.id) == [item.id]
      assert Items.search_active_items("SEARCH") == []
      assert Items.search_active_items("SEARCH-3") == []

      for blank <- [nil, "", "  "] do
        assert Enum.map(Items.search_active_items(blank), & &1.id) == [item.id, other.id]
      end
    end
  end

  describe "list_items/1" do
    test "メーカーを preload し、アーカイブ済みは既定で含めない" do
      item = item_fixture()
      archived = item_fixture()
      {:ok, _} = Items.archive_item(user_scope_fixture(), archived)

      entries = Items.list_items(%{}).entries
      assert Enum.any?(entries, &(&1.id == item.id and &1.maker.maker_name == "テストメーカー"))
      refute Enum.any?(entries, &(&1.id == archived.id))
    end
  end

  # 入荷した後に全数を出庫した状態(在庫 0 のロット)を作る
  defp empty_lot!(item) do
    lot = lot_fixture(%{item_id: item.id, case_qty: 1})
    lot |> Ecto.Changeset.change(case_qty: 0) |> FoodVault.Repo.update!()
  end
end
