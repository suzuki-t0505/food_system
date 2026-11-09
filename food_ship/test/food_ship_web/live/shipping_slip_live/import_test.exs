defmodule FoodShipWeb.ShippingSlipLive.ImportTest do
  # CSV 一括取込(F-S5)。Task から Req.Test・DB を使うため async: false(共有モード)
  use FoodShipWeb.ConnCase, async: false

  import Ecto.Query
  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodShip.{InventoryStub, Repo}
  alias FoodShip.ShippingSlips.ShippingSlip

  setup {Req.Test, :set_req_test_from_context}

  setup do
    InventoryStub.stub_defaults()
    client_fixture(%{client_code: "CL1"})
    shipping_item_fixture(%{item_code: "IT1"})
    :ok
  end

  @orders "/api/v1/shipment_orders"
  @lot1 "01JE0000000000000000000001"
  @lot2 "01JE0000000000000000000002"
  @header "client_code,client_slip_no,scheduled_ship_date,item_code,order_count"

  defp csv(lines), do: Enum.join([@header | lines], "\n") <> "\n"

  defp order_for(slip) do
    InventoryStub.order(%{
      order_id: Ecto.ULID.generate(),
      external_slip_id: slip.id,
      req_pieces: slip.total_piece_qty,
      allocations: [{@lot1, "2026-12-20", 20}, {@lot2, "2026-12-25", slip.total_piece_qty - 20}]
    })
  end

  defp allocate_ok(conn) do
    slip = Repo.get!(ShippingSlip, conn.assigns.body["external_slip_id"])
    InventoryStub.json(conn, 201, order_for(slip))
  end

  defp allocate_route(fun), do: {"POST", @orders, fun}

  defp slips, do: Repo.all(from s in ShippingSlip, order_by: s.slip_no)
  defp slip_count, do: Repo.aggregate(ShippingSlip, :count)

  # ファイルを選んで送信する
  defp submit_csv(lv, content, name \\ "slips.csv") do
    input =
      file_input(lv, "#import-form", :csv, [%{name: name, content: content, type: "text/csv"}])

    render_upload(input, name)
    lv |> form("#import-form") |> render_submit()
  end

  test "未ログインはログイン画面へ", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/shipping_slips/import")
  end

  describe "viewer" do
    @describetag role: :viewer
    setup :register_and_log_in_user

    test "入れない", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
               live(conn, ~p"/shipping_slips/import")
    end
  end

  describe "staff" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "取り込むと、全行を csv で保存し、引当の結果を行ごとに表示する", %{conn: conn} do
      InventoryStub.routes([
        allocate_route(fn conn ->
          slip = Repo.get!(ShippingSlip, conn.assigns.body["external_slip_id"])

          if slip.client_slip_no == "A-2" do
            InventoryStub.error(conn, 422, "insufficient_stock", %{
              "shortages" => [%{"item_id" => "x", "shortage_pieces" => 4}]
            })
          else
            InventoryStub.json(conn, 201, order_for(slip))
          end
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")

      submit_csv(
        lv,
        csv([
          "CL1,A-1,2026-11-22,IT1,3",
          "CL1,A-2,2026-11-20,IT1,5",
          "CL1,A-3,2026-11-20,IT1,1"
        ])
      )

      wait_until(fn -> assert has_element?(lv, "#import-summary") end)

      assert render(lv) =~ "3 件を処理しました(引当済み 2 件・在庫不足 1 件)。"
      assert has_element?(lv, "#import-progress", "3 / 3 件")
      assert has_element?(lv, "#import-results", "在庫不足(不足 4 個)")
      assert has_element?(lv, "#go-to-slips", "2026-11-20")

      assert has_element?(lv, "#import-results", "引当済み")

      saved = slips()
      assert Enum.map(saved, & &1.client_slip_no) == ["A-1", "A-2", "A-3"]
      assert Enum.all?(saved, &(&1.input_source == :csv))
      assert Enum.map(saved, & &1.status) == [:allocated, :shortage, :allocated]

      # 引当は 出荷予定日 → ファイル順(A-2, A-3, A-1)
      posted =
        for {"POST", @orders, %{"external_slip_id" => id}} <- InventoryStub.calls(), do: id

      by_id = Map.new(saved, &{&1.id, &1.client_slip_no})
      assert Enum.map(posted, &by_id[&1]) == ["A-2", "A-3", "A-1"]
    end

    test "検証エラーが 1 行でもあれば、行番号つきで一覧し、何も保存せず在庫 API も呼ばない", %{conn: conn} do
      InventoryStub.routes([])
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")

      submit_csv(
        lv,
        csv([
          "CL1,A-1,2026-11-20,IT1,3",
          "CL1,,2026-11-20,IT1,3",
          "NOPE,A-3,2026-11-20,IT1,3",
          "CL1,A-1,2026-11-21,IT1,3"
        ])
      )

      assert has_element?(lv, "#import-errors", "検証エラーが 3 件あります")
      assert has_element?(lv, "#import-errors", "3 行目")
      assert has_element?(lv, "#import-errors", "client_slip_no は必須です。")
      assert has_element?(lv, "#import-errors", "4 行目")
      assert has_element?(lv, "#import-errors", "client_code「NOPE」は登録されていません。")
      assert has_element?(lv, "#import-errors", "5 行目")
      assert has_element?(lv, "#import-errors", "2 行目と重複しています")

      refute has_element?(lv, "#import-result")
      assert slip_count() == 0
      assert InventoryStub.calls() == []
    end

    test "見出しが違う・UTF-8 でないファイルは、ファイル単位のエラーを表示する", %{conn: conn} do
      InventoryStub.routes([])
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")

      submit_csv(lv, "a,b,c\n1,2,3\n")
      assert has_element?(lv, "#import-file-error", "1 行目の見出しが正しくありません")

      submit_csv(lv, @header <> "\nCL1,\xFF,2026-11-20,IT1,3\n")
      assert has_element?(lv, "#import-file-error", "UTF-8")

      assert slip_count() == 0
      assert InventoryStub.calls() == []
    end

    test "CSV 以外の拡張子は選べない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")

      input =
        file_input(lv, "#import-form", :csv, [
          %{name: "slips.xlsx", content: "x", type: "text/plain"}
        ])

      assert {:error, _} = render_upload(input, "slips.xlsx")
      assert has_element?(lv, "#import-submit[disabled]")
    end

    test "ファイルを選ばずに送信すると、案内を表示する", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")

      assert has_element?(lv, "#import-submit[disabled]")
      assert render_submit(lv, "import", %{}) =~ "CSV ファイルを選択してください。"
      assert slip_count() == 0
    end

    test "引当中は送信ボタンと入力が無効になり、二重に取り込めない", %{conn: conn} do
      test_pid = self()

      InventoryStub.routes([
        allocate_route(fn conn ->
          send(test_pid, {:waiting, self()})

          receive do
            :continue -> :ok
          end

          allocate_ok(conn)
        end)
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")
      submit_csv(lv, csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert_receive {:waiting, api_pid}, 2000
      assert has_element?(lv, "#import-submit[disabled]")
      assert has_element?(lv, "#import-progress", "0 / 1 件")
      assert has_element?(lv, "#import-results", "処理待ち")

      # 実行中にもう一度送っても、何も起きない
      render_submit(lv, "import", %{})
      send(api_pid, :continue)

      wait_until(fn -> assert has_element?(lv, "#import-summary") end)

      assert slip_count() == 1
      assert [%{status: :allocated}] = slips()
    end

    test "引当の Task が途中で止まると中断を知らせ、残りは pending のまま残る", %{conn: conn} do
      InventoryStub.routes([allocate_route(fn _conn -> Process.exit(self(), :kill) end)])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")
      submit_csv(lv, csv(["CL1,A-1,2026-11-20,IT1,3", "CL1,A-2,2026-11-20,IT1,3"]))

      wait_until(fn -> assert render(lv) =~ "引当の処理が中断しました" end)

      assert Enum.map(slips(), & &1.status) == [:pending, :pending]
      refute has_element?(lv, "#import-summary")
    end

    test "デフォルト倉庫が未設定なら、警告を出し、取り込めない", %{conn: conn} do
      InventoryStub.routes([
        {"GET", "/api/v1/warehouses", &InventoryStub.without_default_warehouse/1}
      ])

      {:ok, lv, _} = live(conn, ~p"/shipping_slips/import")
      assert has_element?(lv, "#warehouse-warning")

      submit_csv(lv, csv(["CL1,A-1,2026-11-20,IT1,3"]))
      assert render(lv) =~ "対象倉庫が設定されていません。"
      assert slip_count() == 0
    end
  end

  test "作業画面から取込画面へ移動できる(staff)", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: :staff, must_change_password: false}))

    {:ok, lv, _} = live(conn, ~p"/shipping_slips")
    assert has_element?(lv, "#import-csv")

    assert {:ok, _lv, html} =
             lv |> element("#import-csv") |> render_click() |> follow_redirect(conn)

    assert html =~ "CSV 一括取込"
  end
end
