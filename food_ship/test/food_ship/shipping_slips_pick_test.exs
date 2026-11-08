defmodule FoodShip.ShippingSlipsPickTest do
  # 伝票の変更とトータルピックの連動(紐づき済みの伝票が外れ、ピックが要再発行になる)
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.TotalPicksFixtures

  alias FoodShip.InventoryStub
  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  @orders "/api/v1/shipment_orders"
  @date ~D[2026-11-20]

  defp slip_row(slip), do: Repo.get!(ShippingSlip, slip.id)
  defp pick_row(pick), do: Repo.get!(TotalPick, pick.id)

  defp remote_order(slip, status) do
    InventoryStub.order(%{
      order_id: slip.inventory_order_id,
      external_slip_id: slip.id,
      req_pieces: slip.total_piece_qty,
      status: status,
      shipped_at: if(status == "shipped", do: "2026-11-20T01:02:03Z")
    })
  end

  defp route_cancel_ok(slip) do
    InventoryStub.routes([
      {"GET", @orders,
       fn conn ->
         InventoryStub.json(conn, 200, %{"shipment_orders" => [remote_order(slip, "allocated")]})
       end},
      {"POST", ~r{/cancel$},
       fn conn -> InventoryStub.json(conn, 200, remote_order(slip, "cancelled")) end}
    ])
  end

  describe "update_shipping_slip/3" do
    test "件数の変更で pending に戻ると、ピックから外れてピックが outdated になる" do
      scope = user_scope_fixture()
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)

      assert {:ok, updated} =
               ShippingSlips.update_shipping_slip(scope, slip1, %{
                 "order_count" => "4",
                 "scheduled_ship_date" => "2026-11-20"
               })

      assert updated.status == :pending
      assert updated.total_pick_id == nil
      assert slip_row(slip2).total_pick_id == pick.id
      assert pick_row(pick).status == :outdated
      assert pick_row(pick).revision == 1
    end

    test "出荷予定日の変更でも外れる。最後の 1 件が外れたらピックは cancelled" do
      scope = user_scope_fixture()
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)

      for slip <- [slip1, slip2] do
        {:ok, _} =
          ShippingSlips.update_shipping_slip(scope, slip, %{
            "order_count" => "3",
            "scheduled_ship_date" => "2026-11-25"
          })
      end

      assert slip_row(slip1).total_pick_id == nil
      assert slip_row(slip2).total_pick_id == nil
      assert pick_row(pick).status == :cancelled
    end

    test "ピックに紐づかない伝票の変更は、ピックに影響しない" do
      scope = user_scope_fixture()
      {pick, _slips} = total_pick_fixture(scope: scope)
      other = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)

      assert {:ok, _} =
               ShippingSlips.update_shipping_slip(scope, other, %{
                 "order_count" => "5",
                 "scheduled_ship_date" => "2026-11-20"
               })

      assert pick_row(pick).status == :issued
    end

    test "変更に失敗(検証エラー)したときは、ピックの紐づきも変わらない" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)

      assert {:error, %Ecto.Changeset{}} =
               ShippingSlips.update_shipping_slip(scope, slip1, %{
                 "order_count" => "0",
                 "scheduled_ship_date" => "2026-11-20"
               })

      assert slip_row(slip1).total_pick_id == pick.id
      assert slip_row(slip1).status == :allocated
      assert pick_row(pick).status == :issued
    end
  end

  describe "cancel_shipping_slip/2" do
    test "取消すると、ピックから外れてピックが outdated になる" do
      scope = user_scope_fixture()
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)
      route_cancel_ok(slip1)

      assert {:ok, cancelled} = ShippingSlips.cancel_shipping_slip(scope, slip1)

      assert cancelled.status == :cancelled
      assert cancelled.total_pick_id == nil
      assert slip_row(slip2).total_pick_id == pick.id
      assert pick_row(pick).status == :outdated
    end

    test "最後の 1 件を取り消すと、ピックは cancelled" do
      scope = user_scope_fixture()
      {pick, [slip1]} = total_pick_fixture(scope: scope, slips: 1)
      route_cancel_ok(slip1)

      assert {:ok, %{status: :cancelled}} = ShippingSlips.cancel_shipping_slip(scope, slip1)
      assert pick_row(pick).status == :cancelled
    end

    test "在庫側の解除に失敗したときは、ピックも伝票も変わらない" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)
      InventoryStub.routes([{"GET", @orders, &InventoryStub.timeout/1}])

      assert {:error, :connection} = ShippingSlips.cancel_shipping_slip(scope, slip1)

      assert slip_row(slip1).total_pick_id == pick.id
      assert slip_row(slip1).status == :allocated
      assert pick_row(pick).status == :issued
    end

    test "確保したあとにピックへ紐づけられても、取消の時点の紐づきを読んで外す" do
      scope = user_scope_fixture()
      slip = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)
      item = FoodShip.Repo.preload(slip, :shipping_item).shipping_item

      # 取消の在庫 API 呼び出しの最中にピックが作られた状況を、解除のスタブの中で再現する
      test_pid = self()

      InventoryStub.routes([
        {"GET", @orders,
         fn conn ->
           {:ok, [_pick]} =
             TotalPicks.create_total_picks(scope, @date, [
               {slip.client_id, item.inventory_maker_id}
             ])

           send(test_pid, :picked)

           InventoryStub.json(conn, 200, %{"shipment_orders" => [remote_order(slip, "allocated")]})
         end},
        {"POST", ~r{/cancel$},
         fn conn -> InventoryStub.json(conn, 200, remote_order(slip, "cancelled")) end}
      ])

      # 確保(claim)のあとで API 呼び出しが走るので、伝票はまだ未ピックの状態で確保される
      assert {:ok, %{status: :cancelled, total_pick_id: nil}} =
               ShippingSlips.cancel_shipping_slip(scope, slip)

      assert_received :picked
      [pick] = Repo.all(TotalPick)
      assert pick.status == :cancelled
      assert slip_row(slip).total_pick_id == nil
    end
  end

  describe "pack_shipping_slip/2" do
    test "梱包完了ではピックも紐づきも変わらない" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)

      InventoryStub.routes([
        {"POST", ~r{/ship$},
         fn conn -> InventoryStub.json(conn, 200, remote_order(slip1, "shipped")) end}
      ])

      assert {:ok, packed} = ShippingSlips.pack_shipping_slip(scope, slip1)

      assert packed.status == :packed
      assert packed.total_pick_id == pick.id
      assert pick_row(pick).status == :issued
    end
  end

  describe "list_shipping_slips/2" do
    test ":unpicked は未ピックの引当済み伝票だけを返す。伝票にピックを preload する" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)
      free = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)
      pending = FoodShip.ShippingSlipsFixtures.slip_fixture(%{scheduled_ship_date: @date}, scope)

      assert [%{id: id}] = ShippingSlips.list_shipping_slips(@date, :unpicked)
      assert id == free.id

      all = ShippingSlips.list_shipping_slips(@date, :all)
      assert length(all) == 4
      assert Enum.find(all, &(&1.id == slip1.id)).total_pick.id == pick.id
      assert Enum.find(all, &(&1.id == pending.id)).total_pick == nil
    end
  end
end
