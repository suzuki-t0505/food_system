defmodule FoodShipWeb.ShippingItemLive.IndexTest do
  use FoodShipWeb.ConnCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.InventoryStub
  alias FoodShip.ShippingItems

  setup {Req.Test, :set_req_test_from_context}

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/masters/shipping_items")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧を見られるが、編集・再取得ボタンは出ない", %{conn: conn} do
      item = shipping_item_fixture(%{item_name: "閲覧商品", maker_name: "閲覧メーカー"})
      {:ok, lv, html} = live(conn, ~p"/masters/shipping_items")

      assert html =~ "閲覧商品"
      assert html =~ "閲覧メーカー"
      refute has_element?(lv, "#new-shipping-item")
      refute has_element?(lv, "#edit-shipping-item-#{item.id}")
      refute has_element?(lv, "#refetch-shipping-item-#{item.id}")
    end

    test "イベントを直接送っても再取得・アーカイブできない", %{conn: conn} do
      item = shipping_item_fixture()
      {:ok, lv, _} = live(conn, ~p"/masters/shipping_items")

      assert render_click(lv, "refetch", %{"id" => item.id}) =~ "権限がありません。"
      assert render_click(lv, "archive", %{"id" => item.id}) =~ "権限がありません。"
      refute ShippingItems.get_shipping_item!(item.id).archived_at
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "アーカイブと復帰ができる", %{conn: conn} do
      item = shipping_item_fixture(%{item_name: "操作商品"})
      {:ok, lv, _} = live(conn, ~p"/masters/shipping_items")

      lv |> element("#archive-shipping-item-#{item.id}") |> render_click()
      assert ShippingItems.get_shipping_item!(item.id).archived_at
      refute has_element?(lv, "#shipping-item-#{item.id}")

      lv |> element("#include-archived") |> render_click()
      assert_patch(lv)
      lv |> element("#restore-shipping-item-#{item.id}") |> render_click()
      refute ShippingItems.get_shipping_item!(item.id).archived_at
    end

    test "在庫側の値を再取得して画面と DB を更新する", %{conn: conn} do
      item = shipping_item_fixture(%{item_name: "元の名前"})

      InventoryStub.stub(fn conn ->
        InventoryStub.json(conn, 200, %{
          "items" => [
            %{
              "id" => item.inventory_item_id,
              "item_code" => item.item_code,
              "item_name" => "在庫側で改名",
              "maker_id" => item.inventory_maker_id,
              "maker_name" => item.maker_name
            }
          ]
        })
      end)

      {:ok, lv, _} = live(conn, ~p"/masters/shipping_items")
      lv |> element("#refetch-shipping-item-#{item.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫側の値を再取得しました。" end)
      assert render(lv) =~ "在庫側で改名"
      assert ShippingItems.get_shipping_item!(item.id).item_name == "在庫側で改名"
    end

    test "在庫システムに接続できなければメッセージを出し、値は変えない", %{conn: conn} do
      item = shipping_item_fixture(%{item_name: "元の名前"})
      InventoryStub.stub(&InventoryStub.timeout/1)

      {:ok, lv, _} = live(conn, ~p"/masters/shipping_items")
      lv |> element("#refetch-shipping-item-#{item.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫システムに接続できませんでした。" end)
      assert ShippingItems.get_shipping_item!(item.id).item_name == "元の名前"
    end

    test "在庫側に商品が無ければメッセージを出す", %{conn: conn} do
      item = shipping_item_fixture()
      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 200, %{"items" => []}) end)

      {:ok, lv, _} = live(conn, ~p"/masters/shipping_items")
      lv |> element("#refetch-shipping-item-#{item.id}") |> render_click()

      wait_until(fn -> assert render(lv) =~ "在庫システムに該当する商品が見つかりません。" end)
    end
  end

  test "staff も在庫 API を呼べない(再取得は admin のみ)", %{conn: conn} do
    staff = user_fixture(%{role: :staff, must_change_password: false})
    item = shipping_item_fixture()
    {:ok, lv, _} = conn |> log_in_user(staff) |> live(~p"/masters/shipping_items")

    assert render_click(lv, "refetch", %{"id" => item.id}) =~ "権限がありません。"
  end
end
