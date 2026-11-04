defmodule FoodVaultWeb.Api.V1.WarehouseControllerTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures, only: [user_scope_fixture: 0]
  import FoodVault.MastersFixtures

  alias FoodVault.Warehouses

  test "有効な倉庫をコード順に返す" do
    b = warehouse_fixture(%{warehouse_code: "ZZ-B", warehouse_name: "第2倉庫"})
    a = warehouse_fixture(%{warehouse_code: "ZZ-A", warehouse_name: "第1倉庫"})

    conn = get(api_conn(), "/api/v1/warehouses")

    assert %{"warehouses" => warehouses} = json_response(conn, 200)

    assert Enum.filter(warehouses, &(&1["id"] in [a.id, b.id])) == [
             %{"id" => a.id, "warehouse_code" => "ZZ-A", "warehouse_name" => "第1倉庫"},
             %{"id" => b.id, "warehouse_code" => "ZZ-B", "warehouse_name" => "第2倉庫"}
           ]
  end

  test "アーカイブ済みの倉庫は返さない" do
    archived = warehouse_fixture()
    {:ok, _} = Warehouses.archive_warehouse(user_scope_fixture(), archived)

    conn = get(api_conn(), "/api/v1/warehouses")

    assert %{"warehouses" => warehouses} = json_response(conn, 200)
    refute Enum.any?(warehouses, &(&1["id"] == archived.id))
  end

  test "倉庫が無ければ空配列で 200" do
    assert json_response(get(api_conn(), "/api/v1/warehouses"), 200) == %{"warehouses" => []}
  end

  test "トークンなしは 401" do
    conn = get(unauthenticated_api_conn(), "/api/v1/warehouses")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end
end
