defmodule FoodVaultWeb.Api.V1.ItemControllerTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures, only: [user_scope_fixture: 0]
  import FoodVault.MastersFixtures

  alias FoodVault.Items

  setup do
    maker = maker_fixture(%{maker_name: "メーカーX"})

    item =
      item_fixture(%{
        maker_id: maker.id,
        item_code: "4901234567894",
        item_name: "商品A",
        units_per_case: 12,
        expiration_type: :best_before
      })

    %{maker: maker, item: item}
  end

  test "item_code で完全一致する有効な商品を返す(maker_id・maker_name を含む)", %{maker: maker, item: item} do
    item_fixture(%{item_code: "4901234567895"})

    conn = get(api_conn(), "/api/v1/items?item_code=4901234567894")

    assert json_response(conn, 200) == %{
             "items" => [
               %{
                 "id" => item.id,
                 "item_code" => "4901234567894",
                 "item_name" => "商品A",
                 "maker_id" => maker.id,
                 "maker_name" => "メーカーX",
                 "units_per_case" => 12,
                 "expiration_type" => "best_before"
               }
             ]
           }
  end

  test "部分一致はしない・該当なしは空配列で 200" do
    for code <- ["490123456789", "NOPE"] do
      conn = get(api_conn(), "/api/v1/items?item_code=#{code}")

      assert json_response(conn, 200) == %{"items" => []}
    end
  end

  test "item_code を省略(または空)すると有効な商品すべてをコード順に返す", %{item: item} do
    other = item_fixture(%{item_code: "0000000000001", expiration_type: :none})

    for query <- ["", "?item_code=", "?item_code=%20"] do
      conn = get(api_conn(), "/api/v1/items" <> query)

      assert %{"items" => items} = json_response(conn, 200)
      assert Enum.map(items, & &1["id"]) == [other.id, item.id]
      assert Enum.find(items, &(&1["id"] == other.id))["expiration_type"] == "none"
    end
  end

  test "アーカイブ済みの商品は、item_code を指定しても返さない", %{item: item} do
    {:ok, _} = Items.archive_item(user_scope_fixture(), item)

    for query <- ["", "?item_code=#{item.item_code}"] do
      conn = get(api_conn(), "/api/v1/items" <> query)

      assert json_response(conn, 200) == %{"items" => []}
    end
  end

  test "item_code が配列などの文字列でない値でも 500 にならない" do
    conn = get(api_conn(), "/api/v1/items?item_code[]=a")

    assert %{"items" => [_]} = json_response(conn, 200)
  end

  test "トークンなしは 401" do
    conn = get(unauthenticated_api_conn(), "/api/v1/items")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end
end
