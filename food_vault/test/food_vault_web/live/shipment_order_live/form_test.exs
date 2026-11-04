defmodule FoodVaultWeb.ShipmentOrderLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Repo
  alias FoodVault.ShipmentOrders.ShipmentOrder

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/shipment_orders/new")
  end

  test "viewer は入れない", %{conn: conn} do
    user = user_fixture(%{role: :viewer, must_change_password: false})

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
             conn |> log_in_user(user) |> live(~p"/shipment_orders/new")
  end

  defp order_params(lot, line_attrs) do
    [
      order: %{
        warehouse_id: lot.warehouse_id,
        shipment_date: "2026-11-15",
        lines: %{"0" => Map.merge(%{item_id: lot.item_id}, line_attrs)}
      }
    ]
  end

  for role <- [:staff, :admin] do
    describe "#{role}" do
      @describetag role: role
      setup :register_and_log_in_user

      setup do
        lot = lot_fixture(%{case_qty: 3, piece_qty: 0})
        %{lot: lot}
      end

      test "登録すると自動引当され、詳細へ遷移する", %{conn: conn, lot: lot, user: user} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")

        lv
        |> form("#order-form", order_params(lot, %{req_cases: "1", req_pieces: "5"}))
        |> render_submit()

        order = Repo.one!(ShipmentOrder)
        assert_redirect(lv, ~p"/shipment_orders/#{order.id}")
        assert order.status == :allocated
        assert is_nil(order.external_slip_id)

        detail = FoodVault.ShipmentOrders.get_shipment_order!(order.id)
        assert [%{user_id: user_id}] = detail.events
        assert user_id == user.id
        assert [%{allocated_cases: 1, allocated_pieces: 5}] = hd(detail.lines).allocations
      end

      test "ケース数・バラ数から総数が表示される", %{conn: conn, lot: lot} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")

        lv
        |> form("#order-form", order_params(lot, %{req_cases: "2", req_pieces: "3"}))
        |> render_change()

        # ケース入数 12: 2 × 12 + 3
        assert has_element?(lv, "#line-total-0", "27 個")
      end

      test "在庫不足なら不足数を表示し、オーダーは作らない", %{conn: conn, lot: lot} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")

        html =
          lv
          |> form("#order-form", order_params(lot, %{req_cases: "5", req_pieces: ""}))
          |> render_submit()

        assert html =~ "在庫が不足しています"
        assert has_element?(lv, "#shortages", "不足 2 ケース / 0 バラ")
        assert Repo.aggregate(ShipmentOrder, :count) == 0
      end

      test "数量が 0 ならエラーを表示する", %{conn: conn, lot: lot} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")

        html =
          lv
          |> form("#order-form", order_params(lot, %{req_cases: "0", req_pieces: "0"}))
          |> render_submit()

        assert html =~ "ケース数かバラ数のどちらかは 1 以上にしてください"
        assert Repo.aggregate(ShipmentOrder, :count) == 0
      end

      test "明細を追加・削除できる", %{conn: conn} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")
        refute has_element?(lv, "#remove-line-0")

        lv |> element("#add-line") |> render_click()
        assert has_element?(lv, "#line-1")
        assert has_element?(lv, "#remove-line-1")

        lv |> element("#remove-line-1") |> render_click()
        refute has_element?(lv, "#line-1")
      end

      test "複数明細を登録できる", %{conn: conn, lot: lot} do
        other = lot_fixture(%{warehouse_id: lot.warehouse_id, case_qty: 2})
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")
        lv |> element("#add-line") |> render_click()

        lv
        |> form("#order-form",
          order: %{
            warehouse_id: lot.warehouse_id,
            shipment_date: "2026-11-15",
            lines: %{
              "0" => %{item_id: lot.item_id, req_cases: "1"},
              "1" => %{item_id: other.item_id, req_cases: "2"}
            }
          }
        )
        |> render_submit()

        order = Repo.one!(ShipmentOrder)
        assert length(FoodVault.ShipmentOrders.get_shipment_order!(order.id).lines) == 2
      end

      test "external_slip_id を送っても画面登録として扱う", %{conn: conn, lot: lot} do
        {:ok, lv, _} = live(conn, ~p"/shipment_orders/new")

        # 画面に無い入力は form/3 では送れないので、イベントに直接渡す
        render_submit(lv, "save", %{
          "order" => %{
            "warehouse_id" => lot.warehouse_id,
            "shipment_date" => "2026-11-15",
            "external_slip_id" => "HACK",
            "lines" => %{"0" => %{"item_id" => lot.item_id, "req_cases" => "1"}}
          }
        })

        assert is_nil(Repo.one!(ShipmentOrder).external_slip_id)
      end
    end
  end
end
