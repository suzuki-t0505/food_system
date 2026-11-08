defmodule FoodShip.TotalPicksConcurrencyTest do
  # 実コミットで複数プロセスから同時に更新するため async: false
  use FoodShip.ConcurrencyCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures

  alias FoodShip.Repo
  alias FoodShip.ShippingSlips
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

  test "ピックの取消と伝票の数量変更を同時に実行しても、デッドロックせず整合する" do
    scope = user_scope_fixture()
    {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)

    results =
      concurrently(3, fn
        1 -> TotalPicks.cancel_total_pick(scope, pick)
        2 -> ShippingSlips.update_shipping_slip(scope, slip1, %{"order_count" => "4"})
        3 -> ShippingSlips.update_shipping_slip(scope, slip2, %{"order_count" => "5"})
      end)

    # 取消は、先に伝票の変更でピックが自動で cancelled になっていれば :invalid_status
    [cancel_result | update_results] = results
    assert match?({:ok, _}, cancel_result) or cancel_result == {:error, :invalid_status}
    assert Enum.all?(update_results, &match?({:ok, _}, &1))

    # どの順で進んでも、最終的にピックは cancelled で、伝票はピックから外れている
    assert Repo.get!(TotalPick, pick.id).status == :cancelled

    for slip <- [slip1, slip2] do
      assert Repo.get!(ShippingSlip, slip.id).total_pick_id == nil
    end
  end
end
