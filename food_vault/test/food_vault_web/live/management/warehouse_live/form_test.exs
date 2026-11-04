defmodule FoodVaultWeb.Management.WarehouseLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Warehouses

  describe "アクセス制御" do
    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/warehouses/new")
      end
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "登録と編集ができる", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/warehouses/new")

      lv
      |> form("#warehouse-form", warehouse: %{warehouse_code: "WH01", warehouse_name: "第1"})
      |> render_submit()

      assert_redirect(lv, ~p"/masters/warehouses")
      warehouse = Enum.find(Warehouses.all_warehouses(), &(&1.warehouse_code == "WH01"))

      {:ok, lv, _} = live(conn, ~p"/management/warehouses/#{warehouse.id}/edit")
      lv |> form("#warehouse-form", warehouse: %{warehouse_name: "改名"}) |> render_submit()
      assert Warehouses.get_warehouse!(warehouse.id).warehouse_name == "改名"
    end

    test "コードの重複はエラー", %{conn: conn} do
      existing = warehouse_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/warehouses/new")

      html =
        lv
        |> form("#warehouse-form",
          warehouse: %{warehouse_code: existing.warehouse_code, warehouse_name: "x"}
        )
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end
end
