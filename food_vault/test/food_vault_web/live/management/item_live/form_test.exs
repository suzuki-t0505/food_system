defmodule FoodVaultWeb.Management.ItemLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.Items
  alias FoodVault.Repo

  describe "アクセス制御" do
    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/items/new")
      end
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "登録できる", %{conn: conn} do
      maker = maker_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/items/new")

      lv
      |> form("#item-form",
        item: %{
          item_code: "IT01",
          item_name: "新商品",
          maker_id: maker.id,
          units_per_case: 6,
          expiration_type: "consumption"
        }
      )
      |> render_submit()

      assert_redirect(lv, ~p"/masters/items")
      item = Enum.find(Items.all_items(), &(&1.item_code == "IT01"))
      assert item.units_per_case == 6
      assert item.expiration_type == :consumption
    end

    test "入数が 0 ならエラー", %{conn: conn} do
      maker = maker_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/items/new")

      html =
        lv
        |> form("#item-form",
          item: %{
            item_code: "IT02",
            item_name: "x",
            maker_id: maker.id,
            units_per_case: 0,
            expiration_type: "none"
          }
        )
        |> render_submit()

      assert html =~ "must be greater than or equal to 1"
    end

    test "ロットがある商品は入数・期限区分の欄が無効になり、変更されない", %{conn: conn} do
      item = item_fixture(%{units_per_case: 12, expiration_type: :best_before})

      Repo.insert!(%InventoryLot{
        warehouse_id: warehouse_fixture().id,
        item_id: item.id,
        expiration_date: ~D[2027-01-01],
        received_date: ~D[2026-11-01]
      })

      {:ok, lv, html} = live(conn, ~p"/management/items/#{item.id}/edit")
      assert html =~ "ロットがあるため、ケース入数と期限区分は変更できません。"
      assert has_element?(lv, "input[name='item[units_per_case]'][disabled]")

      lv |> form("#item-form", item: %{item_name: "改名"}) |> render_submit()

      reloaded = Items.get_item!(item.id)
      assert reloaded.item_name == "改名"
      assert reloaded.units_per_case == 12
      assert reloaded.expiration_type == :best_before
    end
  end
end
