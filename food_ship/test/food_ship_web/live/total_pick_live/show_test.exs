defmodule FoodShipWeb.TotalPickLive.ShowTest do
  use FoodShipWeb.ConnCase, async: false

  import Ecto.Query
  import FoodShip.AccountsFixtures
  import FoodShip.TotalPicksFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.Repo
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks.TotalPick

  setup {Req.Test, :set_req_test_from_context}

  defp pick_row(pick), do: Repo.get!(TotalPick, pick.id)

  defp detach(slip) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
      set: [total_pick_id: nil]
    )
  end

  test "未ログインはログイン画面へ", %{conn: conn} do
    {pick, _} = total_pick_fixture()
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/total_picks/#{pick.id}")
  end

  describe "viewer(参照のみ)" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "明細・仕分け・伝票を見られるが、PDF・再発行・取消は出ない", %{conn: conn} do
      {pick, [slip1, _slip2]} = total_pick_fixture()

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")

      assert has_element?(lv, "#pick-summary", "2026-11-20")
      assert has_element?(lv, "#pick-lines", "2026-12-20")
      assert has_element?(lv, "#pick-lines", ShippingSlip.slip_no_label(slip1))
      assert has_element?(lv, "#pick-slips", ShippingSlip.slip_no_label(slip1))
      refute has_element?(lv, "#pick-actions")
      refute has_element?(lv, "#download-pick")
      refute has_element?(lv, "#work-order-#{slip1.id}")
    end

    test "イベントを直接送っても、取消・再発行はできない", %{conn: conn} do
      {pick, _} = total_pick_fixture()
      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")

      assert render_click(lv, "cancel", %{}) =~ "権限がありません。"
      assert render_click(lv, "reissue", %{}) =~ "権限がありません。"
      assert pick_row(pick).status == :issued
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "合算（商品 × 期限日）・仕分け内訳・合計を表示する", %{conn: conn, scope: scope} do
      client = FoodShip.MastersFixtures.client_fixture()
      item = FoodShip.MastersFixtures.shipping_item_fixture()

      attrs = %{
        client_id: client.id,
        shipping_item_id: item.id,
        scheduled_ship_date: ~D[2026-11-20]
      }

      s1 =
        allocated_slip_fixture(attrs,
          scope: scope,
          lots: [{"2026-12-20", 20}, {"9999-12-31", 16}]
        )

      s2 =
        allocated_slip_fixture(attrs, scope: scope, lots: [{"2026-12-20", 30}, {"2026-12-25", 6}])

      {:ok, [pick]} =
        FoodShip.TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item.inventory_maker_id}
        ])

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")

      html = lv |> element("#pick-lines") |> render()
      assert html =~ "2026-12-20"
      assert html =~ "2026-12-25"
      assert html =~ "期限なし"
      assert html =~ "#{ShippingSlip.slip_no_label(s1)} × 20"
      assert html =~ "#{ShippingSlip.slip_no_label(s2)} × 30"
      assert has_element?(lv, "#pick-totals", "72")
    end

    test "issued は PDF（ピック表・束ね）と作業指示書へのリンクを出し、再発行は出ない", %{conn: conn} do
      {pick, [slip, _]} = total_pick_fixture()

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")

      assert has_element?(lv, "#download-pick[href='/reports/total_picks/#{pick.id}']")
      assert has_element?(lv, "#download-bundle[href='/reports/total_picks/#{pick.id}/bundle']")
      assert has_element?(lv, "#work-order-#{slip.id}[href='/reports/work_orders/#{slip.id}']")
      refute has_element?(lv, "#reissue-pick")
      refute has_element?(lv, "#outdated-note")
    end

    test "outdated は PDF を出さず、再発行すると issued に戻って PDF を出す", %{conn: conn, scope: scope} do
      {pick, [slip1, _slip2]} = total_pick_fixture(scope: scope)
      detach(slip1)
      :ok = FoodShip.TotalPicks.release(Repo, %{total_pick_id: pick.id})

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")

      assert has_element?(lv, "#outdated-note")
      refute has_element?(lv, "#download-pick")
      refute has_element?(lv, "#download-bundle")

      lv |> element("#reissue-pick") |> render_click()

      assert has_element?(lv, "#download-pick")
      refute has_element?(lv, "#outdated-note")
      assert render(lv) =~ "再発行しました。"
      assert pick_row(pick).status == :issued
      assert pick_row(pick).revision == 2
    end

    test "取消すると cancelled になり、伝票は未ピックに戻る", %{conn: conn} do
      {pick, [slip1, slip2]} = total_pick_fixture()

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")
      lv |> element("#cancel-pick") |> render_click()

      assert pick_row(pick).status == :cancelled
      assert Repo.get!(ShippingSlip, slip1.id).total_pick_id == nil
      assert Repo.get!(ShippingSlip, slip2.id).total_pick_id == nil
      refute has_element?(lv, "#download-pick")
      refute has_element?(lv, "#cancel-pick")
      assert render(lv) =~ "取り消しました。"
    end

    test "梱包済みの伝票があると取消できない", %{conn: conn} do
      {pick, [slip1, _]} = total_pick_fixture()

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip1.id),
        set: [
          status: :packed,
          packed_at: DateTime.utc_now(:second),
          packed_by_user_id: user_fixture().id
        ]
      )

      {:ok, lv, _} = live(conn, ~p"/total_picks/#{pick.id}")
      html = lv |> element("#cancel-pick") |> render_click()

      assert html =~ "梱包済みの伝票があるため、取り消せません。"
      assert pick_row(pick).status == :issued
    end

    test "存在しないピックは 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/total_picks/#{Ecto.ULID.generate()}")
      end
    end
  end
end
