defmodule FoodVaultWeb.Api.V1.ShipmentOrderConcurrencyTest do
  # ConnCase は使わない(Sandbox のトランザクションの中だと、他のプロセスから見えない)
  use FoodVault.ConcurrencyCase, async: false

  import Phoenix.ConnTest
  import FoodVaultWeb.ConnCase, only: [api_conn: 0]

  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.Repo
  alias FoodVault.ShipmentOrders.ShipmentOrder

  @endpoint FoodVaultWeb.Endpoint

  test "同じ external_slip_id の同時 POST は 500 にならず、オーダーは 1 件だけできる" do
    item = item_fixture()
    lot = lot_fixture(%{item_id: item.id, case_qty: 10})

    body =
      Jason.encode!(%{
        "warehouse_id" => lot.warehouse_id,
        "shipment_date" => "2026-11-15",
        "external_slip_id" => "SLIP-RACE",
        "operator" => "staff@example.com",
        "lines" => [%{"item_id" => item.id, "req_cases" => 1, "req_pieces" => 0}]
      })

    results =
      concurrently(5, fn _ ->
        conn = post(api_conn(), "/api/v1/shipment_orders", body)
        {conn.status, Jason.decode!(conn.resp_body)}
      end)

    statuses = Enum.map(results, &elem(&1, 0))
    assert Enum.all?(statuses, &(&1 in [200, 201])), "想定外のステータス: #{inspect(statuses)}"
    assert Enum.count(statuses, &(&1 == 201)) == 1

    order_ids = results |> Enum.map(fn {_, body} -> body["order_id"] end) |> Enum.uniq()
    assert [_one] = order_ids
    assert Repo.aggregate(ShipmentOrder, :count) == 1
  end
end
