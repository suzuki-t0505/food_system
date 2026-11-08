defmodule FoodShip.TotalPicksTest do
  # Req.Test のスタブ(引当済み伝票の準備)を扱うため async: false
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures

  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  @date ~D[2026-11-20]

  defp viewer_scope,
    do: user_scope_fixture(user_fixture(%{role: :viewer, must_change_password: false}))

  defp slip_row(slip), do: Repo.get!(ShippingSlip, slip.id)
  defp pick_row(pick), do: Repo.get!(TotalPick, pick.id)

  defp set_status(slip, status, extra) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
      set: [status: status] ++ extra
    )
  end

  defp pack(slip) do
    set_status(slip, :packed,
      packed_at: DateTime.utc_now(:second),
      packed_by_user_id: user_fixture().id
    )
  end

  describe "list_candidates/1" do
    test "未ピックの引当済み伝票を、発注元 × メーカーのグループに分けて数える" do
      client_a = client_fixture()
      client_b = client_fixture()
      item1 = shipping_item_fixture()
      item2 = shipping_item_fixture(%{inventory_maker_id: item1.inventory_maker_id})
      item3 = shipping_item_fixture()

      for {client, item} <- [
            {client_a, item1},
            {client_a, item2},
            {client_a, item3},
            {client_b, item1}
          ] do
        allocated_slip_fixture(%{
          client_id: client.id,
          shipping_item_id: item.id,
          scheduled_ship_date: @date
        })
      end

      groups = TotalPicks.list_candidates(@date)

      assert length(groups) == 3

      same_maker =
        Enum.find(
          groups,
          &(&1.client_id == client_a.id and &1.inventory_maker_id == item1.inventory_maker_id)
        )

      assert same_maker.slip_count == 2
      assert same_maker.item_count == 2
      # 1 伝票 = 3 件 × 12 バラ = 36 バラ
      assert same_maker.total_pieces == 72
      assert same_maker.client_name == client_a.client_name
      assert same_maker.maker_name == item1.maker_name
    end

    test "引当済み以外・ピック済み・別の日付の伝票は対象にしない" do
      client = client_fixture()
      item = shipping_item_fixture()
      attrs = %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: @date}

      picked = allocated_slip_fixture(attrs)
      packed = allocated_slip_fixture(attrs)
      other_day = allocated_slip_fixture(%{attrs | scheduled_ship_date: ~D[2026-11-21]})
      _target = allocated_slip_fixture(attrs)
      _pending = FoodShip.ShippingSlipsFixtures.slip_fixture(attrs)

      scope = user_scope_fixture()
      pack(packed)

      {:ok, _} =
        TotalPicks.create_total_picks(scope, @date, [{client.id, item.inventory_maker_id}])

      # 作成後に増えた伝票だけが候補になる
      refute slip_row(picked).total_pick_id == nil
      assert TotalPicks.list_candidates(@date) == []

      _added = allocated_slip_fixture(attrs)
      assert [%{slip_count: 1}] = TotalPicks.list_candidates(@date)
      assert [%{slip_count: 1}] = TotalPicks.list_candidates(~D[2026-11-21])
      assert slip_row(other_day).total_pick_id == nil
    end
  end

  describe "create_total_picks/3" do
    test "グループごとにピックを作り、伝票を紐づける" do
      scope = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture(%{maker_name: "山田食品"})
      other_item = shipping_item_fixture()

      slips =
        for i <- [item, item, other_item] do
          allocated_slip_fixture(%{
            client_id: client.id,
            shipping_item_id: i.id,
            scheduled_ship_date: @date
          })
        end

      groups = [
        {client.id, item.inventory_maker_id},
        {client.id, other_item.inventory_maker_id}
      ]

      assert {:ok, picks} = TotalPicks.create_total_picks(scope, @date, groups)
      assert length(picks) == 2

      pick = Enum.find(picks, &(&1.inventory_maker_id == item.inventory_maker_id))
      assert pick.status == :issued
      assert pick.revision == 1
      assert pick.maker_name == "山田食品"
      assert pick.client_id == client.id
      assert pick.scheduled_ship_date == @date
      assert pick.issued_by_user_id == scope.user.id
      assert is_integer(pick.pick_no)
      assert TotalPick.pick_no_label(%{pick | pick_no: 45}) == "TP-000045"

      [s1, s2, s3] = slips
      assert slip_row(s1).total_pick_id == pick.id
      assert slip_row(s2).total_pick_id == pick.id
      refute slip_row(s3).total_pick_id in [nil, pick.id]
    end

    test "追加伝票は別のピックになり、既存のピックは変わらない" do
      scope = user_scope_fixture()
      {first, [slip1, slip2]} = total_pick_fixture(scope: scope)
      item = hd(first.shipping_slips).shipping_item
      attrs = %{client_id: first.client_id, shipping_item_id: item.id, scheduled_ship_date: @date}
      added = allocated_slip_fixture(attrs, scope: scope)

      {:ok, [second]} =
        TotalPicks.create_total_picks(scope, @date, [{first.client_id, item.inventory_maker_id}])

      assert second.id != first.id
      assert slip_row(added).total_pick_id == second.id
      assert slip_row(slip1).total_pick_id == first.id
      assert slip_row(slip2).total_pick_id == first.id
      assert pick_row(first).status == :issued
      assert pick_row(first).revision == 1
    end

    test "梱包済み・ピック済みの伝票は対象にならない(対象 0 件は :no_target)" do
      scope = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture()
      attrs = %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: @date}
      slip = allocated_slip_fixture(attrs, scope: scope)
      pack(slip)

      group = {client.id, item.inventory_maker_id}
      assert {:error, :no_target} = TotalPicks.create_total_picks(scope, @date, [group])
      assert Repo.aggregate(TotalPick, :count) == 0
    end

    test "どれかのグループの対象が 0 件なら、全体をロールバックする" do
      scope = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture()

      slip =
        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: @date},
          scope: scope
        )

      groups = [{client.id, item.inventory_maker_id}, {client.id, Ecto.ULID.generate()}]

      assert {:error, :no_target} = TotalPicks.create_total_picks(scope, @date, groups)
      assert Repo.aggregate(TotalPick, :count) == 0
      assert slip_row(slip).total_pick_id == nil
    end

    test "グループが空なら :empty_selection" do
      assert {:error, :empty_selection} =
               TotalPicks.create_total_picks(user_scope_fixture(), @date, [])
    end

    test "staff 未満は拒否する" do
      client = client_fixture()
      item = shipping_item_fixture()

      allocated_slip_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        scheduled_ship_date: @date
      })

      assert {:error, :forbidden} =
               TotalPicks.create_total_picks(viewer_scope(), @date, [
                 {client.id, item.inventory_maker_id}
               ])

      assert Repo.aggregate(TotalPick, :count) == 0
    end
  end

  describe "release/2" do
    test "残りの伝票があれば issued → outdated" do
      {pick, [slip1, _slip2]} = total_pick_fixture()
      set_status(slip1, :allocated, total_pick_id: nil)

      assert :ok = TotalPicks.release(Repo, %{total_pick_id: pick.id})
      assert pick_row(pick).status == :outdated
    end

    test "最後の 1 件が外れたら cancelled" do
      {pick, [slip1, slip2]} = total_pick_fixture()
      set_status(slip1, :allocated, total_pick_id: nil)
      set_status(slip2, :allocated, total_pick_id: nil)

      assert :ok = TotalPicks.release(Repo, %{total_pick_id: pick.id})
      assert pick_row(pick).status == :cancelled
    end

    test "outdated はそのまま。ピックに紐づかない伝票は何もしない" do
      {pick, [slip1, _slip2]} = total_pick_fixture()
      set_status(slip1, :allocated, total_pick_id: nil)
      TotalPicks.release(Repo, %{total_pick_id: pick.id})

      assert :ok = TotalPicks.release(Repo, %{total_pick_id: pick.id})
      assert pick_row(pick).status == :outdated
      assert :ok = TotalPicks.release(Repo, %{total_pick_id: nil})
    end
  end

  describe "reissue_total_pick/2" do
    test "outdated を再発行すると revision が加算され issued に戻る" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)
      set_status(slip1, :allocated, total_pick_id: nil)
      TotalPicks.release(Repo, %{total_pick_id: pick.id})

      other = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      assert {:ok, reissued} = TotalPicks.reissue_total_pick(other, pick_row(pick))

      assert reissued.status == :issued
      assert reissued.revision == 2
      assert reissued.issued_by_user_id == other.user.id
    end

    test "issued・cancelled は再発行できない" do
      scope = user_scope_fixture()
      {pick, _slips} = total_pick_fixture(scope: scope)

      assert {:error, :invalid_status} = TotalPicks.reissue_total_pick(scope, pick)

      {:ok, cancelled} = TotalPicks.cancel_total_pick(scope, pick)
      assert {:error, :invalid_status} = TotalPicks.reissue_total_pick(scope, cancelled)
      assert pick_row(pick).revision == 1
    end

    test "staff 未満は拒否する" do
      {pick, _slips} = total_pick_fixture()
      assert {:error, :forbidden} = TotalPicks.reissue_total_pick(viewer_scope(), pick)
    end
  end

  describe "cancel_total_pick/2" do
    test "紐づく伝票がすべて引当済みなら取消でき、伝票は未ピックに戻る" do
      scope = user_scope_fixture()
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)

      assert {:ok, cancelled} = TotalPicks.cancel_total_pick(scope, pick)
      assert cancelled.status == :cancelled
      assert slip_row(slip1).total_pick_id == nil
      assert slip_row(slip2).total_pick_id == nil
      assert slip_row(slip1).status == :allocated
      assert [%{slip_count: 2}] = TotalPicks.list_candidates(@date)
    end

    test "outdated でも取消できる" do
      scope = user_scope_fixture()
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)
      set_status(slip1, :allocated, total_pick_id: nil)
      TotalPicks.release(Repo, %{total_pick_id: pick.id})

      assert {:ok, %{status: :cancelled}} = TotalPicks.cancel_total_pick(scope, pick_row(pick))
    end

    test "梱包済みの伝票があれば取消できず、何も変えない" do
      scope = user_scope_fixture()
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)
      pack(slip1)

      assert {:error, :has_packed_slips} = TotalPicks.cancel_total_pick(scope, pick)
      assert pick_row(pick).status == :issued
      assert slip_row(slip1).total_pick_id == pick.id
      assert slip_row(slip2).total_pick_id == pick.id
    end

    test "取消済みは取消できない。staff 未満は拒否する" do
      scope = user_scope_fixture()
      {pick, _slips} = total_pick_fixture(scope: scope)
      assert {:error, :forbidden} = TotalPicks.cancel_total_pick(viewer_scope(), pick)

      {:ok, cancelled} = TotalPicks.cancel_total_pick(scope, pick)
      assert {:error, :invalid_status} = TotalPicks.cancel_total_pick(scope, cancelled)
    end
  end

  describe "summarize/1" do
    test "商品 × 期限日で合算し、仕分け内訳と合計を返す" do
      scope = user_scope_fixture()
      client = client_fixture()
      item_a = shipping_item_fixture(%{item_code: "A001", item_name: "缶詰"})

      item_b =
        shipping_item_fixture(%{
          item_code: "B001",
          item_name: "瓶詰",
          inventory_maker_id: item_a.inventory_maker_id
        })

      base = %{client_id: client.id, scheduled_ship_date: @date}

      # 1 伝票 = 3 件 × 12 バラ = 36 バラ。件数 3・箱数 6
      s1 =
        allocated_slip_fixture(Map.put(base, :shipping_item_id, item_a.id),
          scope: scope,
          lots: [{"2026-12-20", 20}, {"2026-12-25", 16}]
        )

      s2 =
        allocated_slip_fixture(Map.put(base, :shipping_item_id, item_a.id),
          scope: scope,
          lots: [{"2026-12-20", 30}, {"9999-12-31", 6}]
        )

      s3 =
        allocated_slip_fixture(Map.put(base, :shipping_item_id, item_b.id),
          scope: scope,
          lots: [{"2026-12-22", 36}]
        )

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, @date, [{client.id, item_a.inventory_maker_id}])

      # 梱包済みも集計に含む
      pack(s2)

      %{lines: lines, totals: totals} = TotalPicks.summarize(pick)

      assert Enum.map(lines, &{&1.item_code, Date.to_iso8601(&1.expiration_date), &1.pieces}) == [
               {"A001", "2026-12-20", 50},
               {"A001", "2026-12-25", 16},
               {"A001", "9999-12-31", 6},
               {"B001", "2026-12-22", 36}
             ]

      [first, second, third, fourth] = lines

      assert first.slips == [
               %{slip_id: s1.id, slip_no: s1_no(s1), pieces: 20},
               %{slip_id: s2.id, slip_no: s1_no(s2), pieces: 30}
             ]

      # 件数・箱数は商品の先頭行だけ(商品単位の合計)
      assert {first.order_count, first.box_count} == {6, 12}
      assert {second.order_count, second.box_count} == {nil, nil}
      assert {third.order_count, third.box_count} == {nil, nil}
      assert {fourth.order_count, fourth.box_count} == {3, 6}

      assert totals == %{pieces: 108, order_count: 9, box_count: 18}
      assert slip_row(s3).total_pick_id == pick.id
    end

    test "ピックに紐づかない伝票は含めない" do
      {pick, _slips} = total_pick_fixture()
      allocated_slip_fixture(%{scheduled_ship_date: @date})

      assert %{totals: %{pieces: 72, order_count: 6, box_count: 12}} = TotalPicks.summarize(pick)
    end
  end

  describe "list_total_picks/2・get_total_pick!/1" do
    test "出荷予定日・発注元・状態で絞り込み、紐づく伝票数を返す" do
      {pick1, _} = total_pick_fixture(date: ~D[2026-11-20], slips: 2)
      {pick2, _} = total_pick_fixture(date: ~D[2026-11-21], slips: 1)
      scope = user_scope_fixture()
      {:ok, _} = TotalPicks.cancel_total_pick(scope, pick2)

      all = TotalPicks.list_total_picks()
      assert Enum.map(all.entries, & &1.id) == [pick2.id, pick1.id]
      assert Enum.find(all.entries, &(&1.id == pick1.id)).slip_count == 2
      assert Enum.find(all.entries, &(&1.id == pick2.id)).slip_count == 0

      assert [%{id: id}] = TotalPicks.list_total_picks(%{status: :issued}).entries
      assert id == pick1.id

      assert [%{id: id}] =
               TotalPicks.list_total_picks(%{scheduled_ship_date: ~D[2026-11-21]}).entries

      assert id == pick2.id

      assert [%{id: id}] = TotalPicks.list_total_picks(%{client_id: pick1.client_id}).entries
      assert id == pick1.id

      assert [%{id: id}] =
               TotalPicks.list_total_picks(%{inventory_maker_id: pick2.inventory_maker_id}).entries

      assert id == pick2.id

      assert TotalPicks.list_total_picks(%{status: nil}).total_entries == 2
    end

    test "get_total_pick!/1 は伝票を slip_no 昇順で preload する" do
      {pick, [slip1, slip2]} = total_pick_fixture()

      loaded = TotalPicks.get_total_pick!(pick.id)
      assert Enum.map(loaded.shipping_slips, & &1.id) == [slip1.id, slip2.id]
      assert hd(loaded.shipping_slips).shipping_item.item_code
      assert [%{expiration_date: ~D[2026-12-20]}] = hd(loaded.shipping_slips).allocated_lots
      assert loaded.client
      assert loaded.issued_by_user
    end

    test "list_makers/0 はピックを作成済みのメーカーを返す" do
      {pick, _} = total_pick_fixture()

      assert [%{inventory_maker_id: id, maker_name: name}] = TotalPicks.list_makers()
      assert id == pick.inventory_maker_id
      assert name == pick.maker_name
    end
  end

  defp s1_no(slip), do: Repo.get!(ShippingSlip, slip.id).slip_no
end
