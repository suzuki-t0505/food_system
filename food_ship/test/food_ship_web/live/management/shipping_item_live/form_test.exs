defmodule FoodShipWeb.Management.ShippingItemLive.FormTest do
  use FoodShipWeb.ConnCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.InventoryStub
  alias FoodShip.ShippingItems

  setup {Req.Test, :set_req_test_from_context}

  @inventory_item %{
    "id" => "01JC0000000000000000000001",
    "item_code" => "4901",
    "item_name" => "商品A",
    "maker_id" => "01JF0000000000000000000001",
    "maker_name" => "メーカーX"
  }

  defp stub_inventory_item do
    InventoryStub.stub(fn conn ->
      InventoryStub.json(conn, 200, %{"items" => [@inventory_item]})
    end)
  end

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, ~p"/management/shipping_items/new")
    end

    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/shipping_items/new")
      end
    end
  end

  describe "admin: 登録" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "取得前は換算の入力欄が出ない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")

      assert has_element?(lv, "#fetch-form")
      refute has_element?(lv, "#shipping-item-form")
    end

    test "商品コードで在庫側の値を取得し、換算を入力して登録できる", %{conn: conn} do
      stub_inventory_item()
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")

      lv |> form("#fetch-form", %{"item_code" => "4901"}) |> render_submit()

      wait_until(fn -> assert has_element?(lv, "#inventory-item") end)
      html = render(lv)
      assert html =~ "商品A"
      assert html =~ "メーカーX"

      lv
      |> form("#shipping-item-form",
        shipping_item: %{boxes_per_order: "2", pieces_per_order: "24"}
      )
      |> render_submit()

      assert_redirect(lv, ~p"/masters/shipping_items")

      assert [item] = ShippingItems.list_shipping_items()
      assert item.inventory_item_id == "01JC0000000000000000000001"
      assert item.inventory_maker_id == "01JF0000000000000000000001"
      assert item.item_code == "4901"
      assert item.item_name == "商品A"
      assert item.maker_name == "メーカーX"
      assert item.boxes_per_order == 2
      assert item.pieces_per_order == 24
    end

    test "在庫側に無い商品コードはエラーを表示し、登録フォームは出ない", %{conn: conn} do
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"items" => []}) end)
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")

      lv |> form("#fetch-form", %{"item_code" => "9999"}) |> render_submit()

      wait_until(fn -> assert render(lv) =~ "有効な商品が見つかりません" end)
      refute has_element?(lv, "#shipping-item-form")
    end

    test "在庫システムに接続できなければエラーを表示する", %{conn: conn} do
      InventoryStub.stub(&InventoryStub.timeout/1)
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")

      lv |> form("#fetch-form", %{"item_code" => "4901"}) |> render_submit()

      wait_until(fn -> assert render(lv) =~ "在庫システムに接続できませんでした。" end)
      refute has_element?(lv, "#shipping-item-form")
    end

    test "換算が 1 未満ならエラーで保存しない", %{conn: conn} do
      stub_inventory_item()
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")
      lv |> form("#fetch-form", %{"item_code" => "4901"}) |> render_submit()
      wait_until(fn -> assert has_element?(lv, "#shipping-item-form") end)

      html =
        lv
        |> form("#shipping-item-form",
          shipping_item: %{boxes_per_order: "0", pieces_per_order: "1"}
        )
        |> render_submit()

      assert html =~ "must be greater than or equal to 1"
      assert ShippingItems.list_shipping_items() == []
    end

    test "すでに登録済みの商品はエラーを表示する", %{conn: conn} do
      shipping_item_fixture(%{
        inventory_item_id: "01JC0000000000000000000001",
        item_code: "4901"
      })

      stub_inventory_item()
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")
      lv |> form("#fetch-form", %{"item_code" => "4901"}) |> render_submit()
      wait_until(fn -> assert has_element?(lv, "#shipping-item-form") end)

      html =
        lv
        |> form("#shipping-item-form",
          shipping_item: %{boxes_per_order: "1", pieces_per_order: "1"}
        )
        |> render_submit()

      assert html =~ "すでに発送商品として登録されています。"
      assert length(ShippingItems.list_shipping_items()) == 1
    end

    test "取得せずに保存イベントを送っても保存されない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/shipping_items/new")

      html =
        render_click(lv, "save", %{
          "shipping_item" => %{"boxes_per_order" => "1", "pieces_per_order" => "1"}
        })

      assert html =~ "先に商品コードで在庫システムから取得してください。"
      assert ShippingItems.list_shipping_items() == []
    end
  end

  describe "admin: 編集" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "換算だけ編集できる", %{conn: conn} do
      item = shipping_item_fixture()
      {:ok, lv, html} = live(conn, ~p"/management/shipping_items/#{item.id}/edit")

      assert html =~ item.item_name
      refute has_element?(lv, "#fetch-form")

      lv
      |> form("#shipping-item-form",
        shipping_item: %{boxes_per_order: "5", pieces_per_order: "60"}
      )
      |> render_submit()

      assert_redirect(lv, ~p"/masters/shipping_items")
      updated = ShippingItems.get_shipping_item!(item.id)
      assert updated.boxes_per_order == 5
      assert updated.pieces_per_order == 60
    end
  end
end
