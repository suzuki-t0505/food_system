defmodule FoodShipWeb.TotalPickLive.IndexTest do
  use FoodShipWeb.ConnCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/total_picks")
  end

  describe "viewer(全ロールが参照できる)" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "一覧に番号・版・出荷予定日・発注元・メーカー・伝票数・状態を表示する", %{conn: conn} do
      client = client_fixture(%{client_name: "一覧発注元"})
      item = shipping_item_fixture(%{maker_name: "一覧メーカー"})
      {pick, _} = total_pick_fixture(client: client, item: item, slips: 3)

      {:ok, lv, _} = live(conn, ~p"/total_picks")

      row = "#pick-#{pick.id}"
      assert has_element?(lv, row, TotalPick.pick_no_label(pick))
      assert has_element?(lv, row, "一覧発注元")
      assert has_element?(lv, row, "一覧メーカー")
      assert has_element?(lv, row, "2026-11-20")
      assert has_element?(lv, row, "発行済")
      assert has_element?(lv, "#{row} a[href='/total_picks/#{pick.id}']")
    end

    test "ピックが無いときは、その旨を表示する", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/total_picks")
      assert has_element?(lv, "#no-picks")
    end

    test "出荷予定日・発注元・メーカー・状態で絞り込む", %{conn: conn} do
      {pick1, _} = total_pick_fixture(date: ~D[2026-11-20])
      {pick2, _} = total_pick_fixture(date: ~D[2026-11-21])
      {:ok, _} = TotalPicks.cancel_total_pick(user_scope_fixture(), pick2)

      {:ok, lv, _} = live(conn, ~p"/total_picks")
      assert has_element?(lv, "#pick-#{pick1.id}")
      assert has_element?(lv, "#pick-#{pick2.id}")

      lv |> form("#pick-filter", %{"date" => "2026-11-21"}) |> render_change()
      assert_patch(lv, "/total_picks?date=2026-11-21")
      refute has_element?(lv, "#pick-#{pick1.id}")
      assert has_element?(lv, "#pick-#{pick2.id}")

      {:ok, lv, _} = live(conn, ~p"/total_picks?status=cancelled")
      refute has_element?(lv, "#pick-#{pick1.id}")
      assert has_element?(lv, "#pick-#{pick2.id}", "取消")

      {:ok, lv, _} = live(conn, ~p"/total_picks?client_id=#{pick1.client_id}")
      assert has_element?(lv, "#pick-#{pick1.id}")
      refute has_element?(lv, "#pick-#{pick2.id}")

      {:ok, lv, _} = live(conn, ~p"/total_picks?maker_id=#{pick2.inventory_maker_id}")
      refute has_element?(lv, "#pick-#{pick1.id}")
      assert has_element?(lv, "#pick-#{pick2.id}")
    end

    test "不正な絞り込み値・ページは無視する", %{conn: conn} do
      {pick, _} = total_pick_fixture()

      {:ok, lv, _} =
        live(conn, ~p"/total_picks?date=bad&client_id=x&maker_id=y&status=zzz&page=abc")

      assert has_element?(lv, "#pick-#{pick.id}")
    end
  end

  describe "ページ送り" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "21 件以上あるときはページ送りを表示する", %{conn: conn} do
      scope = user_scope_fixture()
      client = client_fixture()
      item = shipping_item_fixture()

      for n <- 1..21 do
        date = Date.add(~D[2026-11-01], n)

        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: date},
          scope: scope
        )

        {:ok, _} =
          TotalPicks.create_total_picks(scope, date, [{client.id, item.inventory_maker_id}])
      end

      {:ok, lv, _} = live(conn, ~p"/total_picks")
      assert has_element?(lv, "#pagination")
      assert lv |> element("#total-picks") |> render() =~ "2026-11-22"
      refute lv |> element("#total-picks") |> render() =~ "2026-11-02"

      {:ok, lv, _} = live(conn, ~p"/total_picks?page=2")
      assert lv |> element("#total-picks") |> render() =~ "2026-11-02"
    end
  end
end
