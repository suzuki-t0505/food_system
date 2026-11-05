defmodule FoodShip.ShippingItemsTest do
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures

  alias FoodShip.InventoryStub
  alias FoodShip.ShippingItems
  alias FoodShip.ShippingItems.ShippingItem

  setup {Req.Test, :set_req_test_from_context}

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      inventory_item_id: Ecto.ULID.generate(),
      item_code: unique_code("I"),
      inventory_maker_id: Ecto.ULID.generate(),
      maker_name: "メーカーX",
      item_name: "商品A",
      boxes_per_order: 1,
      pieces_per_order: 6
    })
  end

  describe "create_shipping_item/2" do
    test "admin は登録できる" do
      assert {:ok, %ShippingItem{boxes_per_order: 1, pieces_per_order: 6}} =
               ShippingItems.create_shipping_item(user_scope_fixture(), valid_attrs())
    end

    test "在庫側の値が無ければ changeset エラー" do
      assert {:error, changeset} = ShippingItems.create_shipping_item(user_scope_fixture(), %{})

      assert %{
               inventory_item_id: ["can't be blank"],
               item_code: ["can't be blank"],
               inventory_maker_id: ["can't be blank"],
               maker_name: ["can't be blank"],
               item_name: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "標準箱数・商品数量は 1 以上" do
      assert {:error, changeset} =
               ShippingItems.create_shipping_item(
                 user_scope_fixture(),
                 valid_attrs(%{boxes_per_order: 0, pieces_per_order: -1})
               )

      assert %{boxes_per_order: [_], pieces_per_order: [_]} = errors_on(changeset)
    end

    test "商品コード・在庫側の商品 ID の重複は拒否する(在庫側の商品と 1 対 1)" do
      item = shipping_item_fixture()

      assert {:error, changeset} =
               ShippingItems.create_shipping_item(
                 user_scope_fixture(),
                 valid_attrs(%{item_code: item.item_code})
               )

      assert %{item_code: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               ShippingItems.create_shipping_item(
                 user_scope_fixture(),
                 valid_attrs(%{inventory_item_id: item.inventory_item_id})
               )

      assert %{inventory_item_id: ["has already been taken"]} = errors_on(changeset)
    end

    for role <- [:staff, :viewer] do
      test "#{role} は拒否する" do
        scope =
          user_scope_fixture(user_fixture(%{role: unquote(role), must_change_password: false}))

        assert {:error, :forbidden} = ShippingItems.create_shipping_item(scope, valid_attrs())
        assert ShippingItems.list_shipping_items(%{"include_archived" => "true"}) == []
      end
    end
  end

  describe "update_shipping_item/3" do
    test "換算だけ更新でき、在庫側の値は変わらない" do
      item = shipping_item_fixture(%{item_name: "元の名前"})

      assert {:ok, updated} =
               ShippingItems.update_shipping_item(user_scope_fixture(), item, %{
                 boxes_per_order: 3,
                 pieces_per_order: 24,
                 item_name: "改名",
                 inventory_item_id: Ecto.ULID.generate()
               })

      assert updated.boxes_per_order == 3
      assert updated.pieces_per_order == 24
      assert updated.item_name == "元の名前"
      assert updated.inventory_item_id == item.inventory_item_id
    end

    test "staff は拒否し、値は変わらない" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      item = shipping_item_fixture()

      assert {:error, :forbidden} =
               ShippingItems.update_shipping_item(scope, item, %{boxes_per_order: 9})

      assert ShippingItems.get_shipping_item!(item.id).boxes_per_order == item.boxes_per_order
    end
  end

  describe "archive_shipping_item/2 と restore_shipping_item/2" do
    test "アーカイブすると選択肢に出ず、復帰すると戻る" do
      scope = user_scope_fixture()
      item = shipping_item_fixture()

      assert {:ok, archived} = ShippingItems.archive_shipping_item(scope, item)
      assert ShippingItem.archived?(archived)
      refute Enum.any?(ShippingItems.all_shipping_items(), &(&1.id == item.id))

      assert {:ok, restored} = ShippingItems.restore_shipping_item(scope, archived)
      refute ShippingItem.archived?(restored)
      assert Enum.any?(ShippingItems.all_shipping_items(), &(&1.id == item.id))
    end
  end

  describe "fetch_inventory_item/1" do
    test "商品コードから在庫側の値を初期入力用の属性にして返す" do
      InventoryStub.stub(fn conn ->
        assert conn.query_string == "item_code=4901"

        InventoryStub.json(conn, 200, %{
          "items" => [
            %{
              "id" => "01JC0000000000000000000001",
              "item_code" => "4901",
              "item_name" => "商品A",
              "maker_id" => "01JF0000000000000000000001",
              "maker_name" => "メーカーX"
            }
          ]
        })
      end)

      assert {:ok,
              %{
                inventory_item_id: "01JC0000000000000000000001",
                item_code: "4901",
                item_name: "商品A",
                inventory_maker_id: "01JF0000000000000000000001",
                maker_name: "メーカーX"
              }} = ShippingItems.fetch_inventory_item(" 4901 ")
    end

    test "在庫側に無い商品コード・空のコードは :not_found" do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"items" => []}) end)

      assert {:error, :not_found} = ShippingItems.fetch_inventory_item("9999")
      assert {:error, :not_found} = ShippingItems.fetch_inventory_item("  ")
    end

    test "通信失敗・認証エラーはそのまま返す" do
      InventoryStub.stub(&InventoryStub.timeout/1)
      assert {:error, :connection} = ShippingItems.fetch_inventory_item("4901")

      InventoryStub.stub(fn conn -> InventoryStub.error(conn, 401, "unauthorized") end)
      assert {:error, :unauthorized} = ShippingItems.fetch_inventory_item("4901")
    end
  end

  describe "refresh_from_inventory/2" do
    defp inventory_item_response(item, attrs) do
      fn conn ->
        InventoryStub.json(conn, 200, %{
          "items" => [
            Map.merge(
              %{
                "id" => item.inventory_item_id,
                "item_code" => item.item_code,
                "item_name" => "在庫側で改名",
                "maker_id" => item.inventory_maker_id,
                "maker_name" => "在庫側のメーカー"
              },
              attrs
            )
          ]
        })
      end
    end

    test "在庫側の値を取り直して更新する(換算は変えない)" do
      item = shipping_item_fixture(%{boxes_per_order: 3})
      new_maker_id = Ecto.ULID.generate()

      InventoryStub.stub(inventory_item_response(item, %{"maker_id" => new_maker_id}))

      assert {:ok, refreshed} = ShippingItems.refresh_from_inventory(user_scope_fixture(), item)
      assert refreshed.item_name == "在庫側で改名"
      assert refreshed.maker_name == "在庫側のメーカー"
      assert refreshed.inventory_maker_id == new_maker_id
      assert refreshed.boxes_per_order == 3
    end

    test "在庫側の商品 ID が違えば :mismatch で更新しない" do
      item = shipping_item_fixture(%{item_name: "元の名前"})

      InventoryStub.stub(inventory_item_response(item, %{"id" => Ecto.ULID.generate()}))

      assert {:error, :mismatch} =
               ShippingItems.refresh_from_inventory(user_scope_fixture(), item)

      assert ShippingItems.get_shipping_item!(item.id).item_name == "元の名前"
    end

    test "在庫側に商品が無ければ :not_found、通信失敗なら :connection(更新しない)" do
      item = shipping_item_fixture(%{item_name: "元の名前"})

      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"items" => []}) end)

      assert {:error, :not_found} =
               ShippingItems.refresh_from_inventory(user_scope_fixture(), item)

      InventoryStub.stub(&InventoryStub.timeout/1)

      assert {:error, :connection} =
               ShippingItems.refresh_from_inventory(user_scope_fixture(), item)

      assert ShippingItems.get_shipping_item!(item.id).item_name == "元の名前"
    end

    test "staff は拒否し、在庫 API を呼ばない" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      item = shipping_item_fixture()

      # スタブ未登録のまま呼ぶと失敗する。呼ばれないことを確認する
      assert {:error, :forbidden} = ShippingItems.refresh_from_inventory(scope, item)
    end
  end
end
