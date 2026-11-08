defmodule FoodShip.TotalPicksConcurrencyTest do
  # 実コミットで複数プロセスから同時に更新するため async: false
  use FoodShip.ConcurrencyCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures

  alias FoodShip.Repo
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  @date ~D[2026-11-20]

  test "同じ伝票に対するピック作成を同時に実行しても、片方だけが成功する(二重ピックにならない)" do
    scope = user_scope_fixture()
    client = client_fixture()
    item = shipping_item_fixture()

    slips =
      for _ <- 1..3 do
        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: @date},
          scope: scope
        )
      end

    group = {client.id, item.inventory_maker_id}

    results = concurrently(4, fn _n -> TotalPicks.create_total_picks(scope, @date, [group]) end)

    assert [{:ok, [pick]}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :no_target})) == 3

    assert Repo.aggregate(TotalPick, :count) == 1

    for slip <- slips do
      assert Repo.get!(ShippingSlip, slip.id).total_pick_id == pick.id
    end
  end

  test "ピックの取消を同時に実行しても、片方だけが成功しデッドロックしない" do
    scope = user_scope_fixture()
    {pick, slips} = total_pick_fixture(scope: scope)

    results = concurrently(3, fn _n -> TotalPicks.cancel_total_pick(scope, pick) end)

    assert Enum.count(results, &match?({:ok, %TotalPick{status: :cancelled}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_status})) == 2
    assert Repo.get!(TotalPick, pick.id).status == :cancelled

    for slip <- slips do
      assert Repo.get!(ShippingSlip, slip.id).total_pick_id == nil
    end
  end
end
