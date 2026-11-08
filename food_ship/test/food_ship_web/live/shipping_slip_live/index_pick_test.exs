defmodule FoodShipWeb.ShippingSlipLive.IndexPickTest do
  # 作業画面のトータルピック関連（ピック番号・未ピックのみ・作成ダイアログ・作業指示書リンク）
  use FoodShipWeb.ConnCase, async: false

  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.Repo
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  @date ~D[2026-11-20]
  @path "/shipping_slips?date=2026-11-20"

  defp row(slip), do: "#slip-#{slip.id}"

  describe "viewer(参照のみ)" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "ピック番号は見られるが、作成ボタン・作業指示書リンクは出ない", %{conn: conn} do
      {pick, [slip, _]} = total_pick_fixture()

      {:ok, lv, _html} = live(conn, @path)

      assert has_element?(lv, "#pick-of-#{slip.id}", TotalPick.pick_no_label(pick))
      refute has_element?(lv, "#open-pick-dialog")
      refute has_element?(lv, "#work-order-#{slip.id}")
    end

    test "イベントを直接送っても、ダイアログは開かずピックも作れない", %{conn: conn} do
      client = client_fixture()
      item = shipping_item_fixture()

      allocated_slip_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        scheduled_ship_date: @date
      })

      {:ok, lv, _html} = live(conn, @path)

      assert render_click(lv, "open_pick_dialog", %{}) =~ "権限がありません。"
      refute has_element?(lv, "#pick-dialog")

      render_click(lv, "create_picks", %{"groups" => ["#{client.id}:#{item.inventory_maker_id}"]})

      assert Repo.aggregate(TotalPick, :count) == 0
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "ピック済みの伝票にピック番号が出て、未ピックのみフィルタで外せる", %{conn: conn, scope: scope} do
      {pick, [picked, _]} = total_pick_fixture(scope: scope)
      free = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)

      {:ok, lv, _} = live(conn, @path)

      assert has_element?(lv, "#pick-of-#{picked.id} a[href='/total_picks/#{pick.id}']")
      refute has_element?(lv, "#pick-of-#{free.id} a")
      assert has_element?(lv, row(picked))

      {:ok, lv, _} = live(conn, "#{@path}&filter=unpicked")

      assert has_element?(lv, row(free))
      refute has_element?(lv, row(picked))
    end

    test "要再発行のピックの伝票には「要再発行」を出す", %{conn: conn, scope: scope} do
      {pick, [slip1, slip2]} = total_pick_fixture(scope: scope)

      {:ok, _} =
        FoodShip.ShippingSlips.update_shipping_slip(scope, slip1, %{
          "order_count" => "4",
          "scheduled_ship_date" => "2026-11-20"
        })

      assert Repo.get!(TotalPick, pick.id).status == :outdated

      {:ok, lv, _} = live(conn, @path)

      assert has_element?(lv, "#pick-of-#{slip2.id}", "要再発行")
    end

    test "引当済み・梱包完了の伝票に作業指示書の PDF リンクを出す", %{conn: conn, scope: scope} do
      allocated = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)
      pending = FoodShip.ShippingSlipsFixtures.slip_fixture(%{scheduled_ship_date: @date}, scope)

      {:ok, lv, _} = live(conn, @path)

      assert has_element?(
               lv,
               "#work-order-#{allocated.id}[href='/reports/work_orders/#{allocated.id}']"
             )

      refute has_element?(lv, "#work-order-#{pending.id}")
    end

    test "取消の確認ダイアログに、ピックから外れる旨を出す", %{conn: conn, scope: scope} do
      {pick, [slip, _]} = total_pick_fixture(scope: scope)
      free = allocated_slip_fixture(%{scheduled_ship_date: @date}, scope: scope)

      {:ok, lv, _} = live(conn, @path)

      cancel = lv |> element("#cancel-#{slip.id}") |> render()
      assert cancel =~ "#{TotalPick.pick_no_label(pick)} から外れ、再発行が必要になります"

      plain = lv |> element("#cancel-#{free.id}") |> render()
      refute plain =~ "から外れ"
    end

    test "ダイアログで未ピックのグループを選んでピックを作り、詳細へ移る", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "ダイアログ発注元"})
      item = shipping_item_fixture(%{maker_name: "ダイアログメーカー"})
      other = shipping_item_fixture(%{maker_name: "別メーカー"})
      attrs = %{client_id: client.id, scheduled_ship_date: @date}

      s1 = allocated_slip_fixture(Map.put(attrs, :shipping_item_id, item.id), scope: scope)
      s2 = allocated_slip_fixture(Map.put(attrs, :shipping_item_id, item.id), scope: scope)
      s3 = allocated_slip_fixture(Map.put(attrs, :shipping_item_id, other.id), scope: scope)

      {:ok, lv, _} = live(conn, @path)
      refute has_element?(lv, "#pick-dialog")

      lv |> element("#open-pick-dialog") |> render_click()

      assert has_element?(lv, "#pick-dialog", "ダイアログ発注元 / ダイアログメーカー")
      assert has_element?(lv, "#pick-dialog", "伝票 2 件・商品 1 種類・合計 72 バラ")
      assert has_element?(lv, "#pick-dialog", "別メーカー")

      # 1 グループだけ選ぶ
      lv
      |> form("#pick-form", %{"groups" => ["#{client.id}:#{item.inventory_maker_id}"]})
      |> render_submit()

      [pick] = Repo.all(TotalPick)
      assert_redirect(lv, "/total_picks/#{pick.id}")

      assert Repo.get!(ShippingSlip, s1.id).total_pick_id == pick.id
      assert Repo.get!(ShippingSlip, s2.id).total_pick_id == pick.id
      assert Repo.get!(ShippingSlip, s3.id).total_pick_id == nil
    end

    test "未ピックの伝票が無いときは、その旨を表示する", %{conn: conn} do
      {:ok, lv, _} = live(conn, @path)

      lv |> element("#open-pick-dialog") |> render_click()
      assert has_element?(lv, "#no-pick-candidates")
      refute has_element?(lv, "#create-picks")

      lv |> element("#close-pick-dialog") |> render_click()
      refute has_element?(lv, "#pick-dialog")
    end

    test "グループを選ばずに作成すると、選択を促す。プレビュー後に伝票が変わったら読み直す", %{conn: conn, scope: scope} do
      client = client_fixture()
      item = shipping_item_fixture()

      slip =
        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: @date},
          scope: scope
        )

      {:ok, lv, _} = live(conn, @path)
      lv |> element("#open-pick-dialog") |> render_click()

      assert lv |> form("#pick-form") |> render_submit(%{"groups" => []}) =~
               "作成するグループを選んでください。"

      # 別の操作で、先にピックされた
      {:ok, _} =
        TotalPicks.create_total_picks(scope, @date, [{client.id, item.inventory_maker_id}])

      html =
        render_submit(lv, "create_picks", %{
          "groups" => ["#{client.id}:#{item.inventory_maker_id}"]
        })

      assert html =~ "対象の伝票が変わりました"
      assert has_element?(lv, "#no-pick-candidates")
      assert Repo.aggregate(TotalPick, :count) == 1
      assert Repo.get!(ShippingSlip, slip.id).total_pick_id
    end

    test "複数のグループを作ると、その日付のピック一覧へ移る", %{conn: conn, scope: scope} do
      client = client_fixture()
      item = shipping_item_fixture()
      other = shipping_item_fixture()

      for i <- [item, other] do
        allocated_slip_fixture(
          %{client_id: client.id, shipping_item_id: i.id, scheduled_ship_date: @date},
          scope: scope
        )
      end

      {:ok, lv, _} = live(conn, @path)
      lv |> element("#open-pick-dialog") |> render_click()
      lv |> form("#pick-form") |> render_submit()

      assert_redirect(lv, "/total_picks?date=2026-11-20")
      assert Repo.aggregate(TotalPick, :count) == 2
    end
  end
end
