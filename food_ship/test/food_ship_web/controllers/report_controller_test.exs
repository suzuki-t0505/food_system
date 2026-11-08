defmodule FoodShipWeb.ReportControllerTest do
  # Req.Test のスタブ（引当済み伝票の準備）と、PDF アダプタの差し替えを扱うため async: false
  use FoodShipWeb.ConnCase, async: false

  import Ecto.Query
  import FoodShip.MastersFixtures
  import FoodShip.TotalPicksFixtures

  alias FoodShip.Repo
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.{ConvertDatetime, Pdf}

  setup {Req.Test, :set_req_test_from_context}

  # PDF アダプタの失敗を再現するためのアダプタ
  defmodule BusyPdf do
    @moduledoc false
    @behaviour FoodShip.Utils.Pdf
    def render(_html), do: {:error, :busy}
    def child_specs(_opts), do: []
  end

  defmodule BrokenPdf do
    @moduledoc false
    @behaviour FoodShip.Utils.Pdf
    def render(_html), do: {:error, {:exit, :boom}}
    def child_specs(_opts), do: []
  end

  defp use_adapter(adapter) do
    original = Application.get_env(:food_ship, Pdf)
    Application.put_env(:food_ship, Pdf, Keyword.put(original, :adapter, adapter))
    on_exit(fn -> Application.put_env(:food_ship, Pdf, original) end)
  end

  defp detach_and_release(pick, slip) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id), set: [total_pick_id: nil])
    :ok = TotalPicks.release(Repo, %{total_pick_id: pick.id})
  end

  defp pdf_html(conn) do
    assert ["application/pdf" <> _] = get_resp_header(conn, "content-type")
    assert "%PDF-FAKE\n" <> html = response(conn, 200)
    html
  end

  @paths [
    "/reports/total_picks/:id",
    "/reports/total_picks/:id/bundle",
    "/reports/work_orders/:id"
  ]

  describe "認可" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      {pick, [slip, _]} = total_pick_fixture()

      for path <- @paths do
        id = if String.contains?(path, "work_orders"), do: slip.id, else: pick.id
        conn = get(conn, String.replace(path, ":id", id))
        assert redirected_to(conn) == "/users/log_in"
      end
    end

    @tag role: :viewer
    test "viewer は出力できない(権限なしでトップへ)", context do
      %{conn: conn} = register_and_log_in_user(context)
      {pick, [slip, _]} = total_pick_fixture()

      for path <- @paths do
        id = if String.contains?(path, "work_orders"), do: slip.id, else: pick.id
        conn = get(conn, String.replace(path, ":id", id))
        assert redirected_to(conn) == "/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == "権限がありません。"
      end
    end
  end

  describe "トータルピック表" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "issued は PDF で返す(ヘッダ・明細・合計・仕分け表。日時は JST)", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "帳票発注元"})
      item = shipping_item_fixture(%{item_name: "帳票商品", maker_name: "帳票メーカー"})

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

      s2 = allocated_slip_fixture(attrs, scope: scope, lots: [{"2026-12-20", 36}])

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item.inventory_maker_id}
        ])

      pick = TotalPicks.get_total_pick!(pick.id)
      conn = get(conn, ~p"/reports/total_picks/#{pick.id}")
      html = pdf_html(conn)

      pick_no = TotalPick.pick_no_label(pick)

      assert get_resp_header(conn, "content-disposition") == [
               ~s(inline; filename="#{pick_no}.pdf")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert html =~ "トータルピック表 #{pick_no}（第1版）"
      assert html =~ "帳票発注元"
      assert html =~ "帳票メーカー"
      assert html =~ "帳票商品"
      assert html =~ item.item_code
      assert html =~ "2026-11-20"
      assert html =~ ConvertDatetime.format_jst(pick.issued_at)
      assert html =~ pick.issued_by_user.email

      # 明細: 2026-12-20 は 20 + 36 = 56、期限なしは 16。合計 72、件数 6、箱数 12
      assert html =~ "期限なし"
      assert html =~ ~r{<td class="num">56</td>}
      assert html =~ ~r{<td class="num">16</td>}

      assert html =~
               ~r{<td colspan="3">合計</td>\s*<td class="num">72</td>\s*<td class="num">6</td>\s*<td class="num">12</td>}

      # 仕分け表
      assert html =~ "仕分け表 #{pick_no}"
      assert html =~ "#{ShippingSlip.slip_no_label(s1)} × 20"
      assert html =~ "#{ShippingSlip.slip_no_label(s2)} × 36"
    end

    test "ピック表のみ（作業指示書を含まない）", %{conn: conn} do
      {pick, _} = total_pick_fixture()
      html = conn |> get(~p"/reports/total_picks/#{pick.id}") |> pdf_html()
      refute html =~ "作業指示書"
    end

    test "outdated は出力せず、詳細へ戻して再発行を促す", %{conn: conn} do
      {pick, [slip1, _]} = total_pick_fixture()
      detach_and_release(pick, slip1)

      for path <- [
            ~p"/reports/total_picks/#{pick.id}",
            ~p"/reports/total_picks/#{pick.id}/bundle"
          ] do
        conn = get(conn, path)
        assert redirected_to(conn) == "/total_picks/#{pick.id}"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "要再発行です"
      end
    end

    test "再発行すると出力できる（版が加算される）", %{conn: conn, scope: scope} do
      {pick, [slip1, _]} = total_pick_fixture(scope: scope)
      detach_and_release(pick, slip1)
      {:ok, _} = TotalPicks.reissue_total_pick(scope, Repo.get!(TotalPick, pick.id))

      html = conn |> get(~p"/reports/total_picks/#{pick.id}") |> pdf_html()
      assert html =~ "（第2版）"
    end

    test "cancelled は出力しない", %{conn: conn, scope: scope} do
      {pick, _} = total_pick_fixture(scope: scope)
      {:ok, _} = TotalPicks.cancel_total_pick(scope, pick)

      conn = get(conn, ~p"/reports/total_picks/#{pick.id}")
      assert redirected_to(conn) == "/total_picks/#{pick.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "取消済み"
    end

    test "存在しないピックは 404", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/reports/total_picks/#{Ecto.ULID.generate()}")
      end
    end
  end

  describe "ピック表＋作業指示書(束ね)" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "ピック表 → 仕分け表 → 作業指示書（slip_no 昇順）の順で 1 つの文書にする", %{conn: conn} do
      {pick, [slip1, slip2]} = total_pick_fixture()
      html = conn |> get(~p"/reports/total_picks/#{pick.id}/bundle") |> pdf_html()

      pick_at = :binary.match(html, "トータルピック表") |> elem(0)
      sort_at = :binary.match(html, "仕分け表") |> elem(0)
      wo1 = :binary.match(html, "作業指示書 #{ShippingSlip.slip_no_label(slip1)}") |> elem(0)
      wo2 = :binary.match(html, "作業指示書 #{ShippingSlip.slip_no_label(slip2)}") |> elem(0)

      assert pick_at < sort_at
      assert sort_at < wo1
      assert wo1 < wo2
      assert html =~ "トータルピック"
      assert html =~ TotalPick.pick_no_label(pick)
    end
  end

  describe "作業指示書" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "伝票の内容・引当ロット・最低許容期限日・所属ピックを出す", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "指示書発注元"})
      item = shipping_item_fixture(%{item_name: "指示書商品", maker_name: "指示書メーカー"})

      _rule =
        expiration_rule_fixture(%{
          client_id: client.id,
          shipping_item_id: item.id,
          min_remaining_days: 30
        })

      slip =
        allocated_slip_fixture(
          %{
            client_id: client.id,
            shipping_item_id: item.id,
            scheduled_ship_date: ~D[2026-11-20],
            client_slip_no: "PO-9"
          },
          scope: scope,
          lots: [{"2026-12-25", 20}, {"9999-12-31", 16}]
        )

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item.inventory_maker_id}
        ])

      html = conn |> get(~p"/reports/work_orders/#{slip.id}") |> pdf_html()

      assert html =~ "作業指示書 #{ShippingSlip.slip_no_label(slip)}"
      assert html =~ "指示書発注元"
      assert html =~ "指示書メーカー"
      assert html =~ "#{item.item_code} 指示書商品"
      assert html =~ "PO-9"
      assert html =~ "2026-11-20"
      assert html =~ "2026-12-20"
      assert html =~ ~r{<td>2026-12-25</td>\s*<td class="num">20</td>}
      assert html =~ ~r{<td>期限なし</td>\s*<td class="num">16</td>}
      assert html =~ TotalPick.pick_no_label(pick)
      assert html =~ "実際の箱数"
      assert html =~ "検品"
    end

    test "ピックに紐づかない伝票は「なし」、発注元伝票番号が無ければ「なし」", %{conn: conn, scope: scope} do
      slip = allocated_slip_fixture(%{}, scope: scope)
      html = conn |> get(~p"/reports/work_orders/#{slip.id}") |> pdf_html()

      assert html =~ ~r{トータルピック</th>\s*<td>なし</td>}
      assert html =~ ~r{発注元伝票番号</th>\s*<td>なし</td>}
      assert html =~ ~r{最低許容期限日</th>\s*<td>なし</td>}
    end

    test "梱包完了の伝票も出力できる", %{conn: conn, scope: scope} do
      slip = allocated_slip_fixture(%{}, scope: scope)

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
        set: [
          status: :packed,
          packed_at: DateTime.utc_now(:second),
          packed_by_user_id: scope.user.id
        ]
      )

      assert conn |> get(~p"/reports/work_orders/#{slip.id}") |> pdf_html() =~ "作業指示書"
    end

    test "引当済み・梱包完了以外は出力せず、作業画面へ戻す", %{conn: conn, scope: scope} do
      pending =
        FoodShip.ShippingSlipsFixtures.slip_fixture(%{scheduled_ship_date: ~D[2026-11-22]}, scope)

      conn = get(conn, ~p"/reports/work_orders/#{pending.id}")

      assert redirected_to(conn) == "/shipping_slips?date=2026-11-22"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "引当済み・梱包完了"
    end
  end

  describe "HTML の安全性" do
    @describetag role: :staff
    setup :register_and_log_in_user

    test "外部リソースを読み込まない（URL・スクリプト・外部 CSS・画像・フォントなし）", %{conn: conn, scope: scope} do
      {pick, [slip | _]} = total_pick_fixture(scope: scope)

      for path <- [
            ~p"/reports/total_picks/#{pick.id}",
            ~p"/reports/total_picks/#{pick.id}/bundle",
            ~p"/reports/work_orders/#{slip.id}"
          ] do
        html = conn |> get(path) |> pdf_html()

        refute html =~ ~r{https?://}
        refute html =~ ~r{<script|<link|<img|<iframe|@import|url\(|@font-face|src=}i
        assert html =~ ~s(lang="ja")
        assert html =~ "Noto Sans"
        assert html =~ "size: A4 portrait"
      end
    end

    test "商品名・発注元名・メーカー名の HTML はエスケープする", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "<script>alert(1)</script>"})
      item = shipping_item_fixture(%{item_name: "<b>太字</b>", maker_name: "A&B"})

      allocated_slip_fixture(
        %{client_id: client.id, shipping_item_id: item.id, scheduled_ship_date: ~D[2026-11-20]},
        scope: scope
      )

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item.inventory_maker_id}
        ])

      html = conn |> get(~p"/reports/total_picks/#{pick.id}/bundle") |> pdf_html()

      refute html =~ "<script>alert"
      refute html =~ "<b>太字</b>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;b&gt;太字&lt;/b&gt;"
      assert html =~ "A&amp;B"
    end
  end

  describe "PDF の生成に失敗したとき" do
    @describetag role: :staff
    @describetag :capture_log
    setup :register_and_log_in_user

    test "プールが混み合っていれば 503", %{conn: conn} do
      {pick, _} = total_pick_fixture()
      use_adapter(BusyPdf)

      conn = get(conn, ~p"/reports/total_picks/#{pick.id}")

      assert response(conn, 503) =~ "混み合っています"
    end

    test "その他の失敗は 500（内部の原因は画面に出さない）", %{conn: conn} do
      {pick, _} = total_pick_fixture()
      use_adapter(BrokenPdf)

      conn = get(conn, ~p"/reports/total_picks/#{pick.id}")

      body = response(conn, 500)
      assert body =~ "PDF を生成できませんでした。"
      refute body =~ "boom"
    end
  end

  # 実 Chromium で帳票を生成する（`PDF_TEST=1`。`PDF_OUT_DIR` を指定すると PDF を書き出す）。
  # 日本語・罫線・A4 縦・改ページは、書き出した PDF を画像にして目視で確認する
  describe "実 Chromium" do
    @describetag :pdf
    @describetag role: :staff
    setup :register_and_log_in_user

    setup do
      original = Application.get_env(:food_ship, Pdf)
      on_exit(fn -> Application.put_env(:food_ship, Pdf, original) end)

      config = Keyword.merge(original, adapter: Pdf.Chromic, start: true, no_sandbox: true)
      Application.put_env(:food_ship, Pdf, config)

      start_supervised!(%{
        id: :chromic_pdf_report_test,
        start: {Supervisor, :start_link, [Pdf.child_specs(), [strategy: :one_for_one]]},
        type: :supervisor
      })

      :ok
    end

    defp write_pdf(name, conn) do
      assert "%PDF" <> _ = body = response(conn, 200)
      if dir = System.get_env("PDF_OUT_DIR"), do: File.write!(Path.join(dir, name), body)
      body
    end

    test "ピック表・束ね・作業指示書を PDF にできる", %{conn: conn, scope: scope} do
      client = client_fixture(%{client_name: "株式会社サンプル百貨店"})

      item_a =
        shipping_item_fixture(%{
          item_code: "A0001",
          item_name: "国産きのこの味わい缶詰セット（化粧箱入り）",
          maker_name: "山田食品株式会社"
        })

      item_b =
        shipping_item_fixture(%{
          item_code: "B0002",
          item_name: "瓶詰 ゆず茶",
          maker_name: "山田食品株式会社",
          inventory_maker_id: item_a.inventory_maker_id
        })

      _rule =
        expiration_rule_fixture(%{
          client_id: client.id,
          shipping_item_id: item_a.id,
          min_remaining_days: 30
        })

      base = %{client_id: client.id, scheduled_ship_date: ~D[2026-11-20]}

      allocated_slip_fixture(
        Map.merge(base, %{shipping_item_id: item_a.id, client_slip_no: "PO-1001"}),
        scope: scope,
        lots: [{"2026-12-20", 20}, {"2027-03-01", 16}]
      )

      allocated_slip_fixture(
        Map.merge(base, %{shipping_item_id: item_a.id, client_slip_no: "PO-1002"}),
        scope: scope,
        lots: [{"2026-12-20", 30}, {"9999-12-31", 6}]
      )

      allocated_slip_fixture(Map.merge(base, %{shipping_item_id: item_b.id}),
        scope: scope,
        lots: [{"2027-01-15", 36}]
      )

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item_a.inventory_maker_id}
        ])

      pick = TotalPicks.get_total_pick!(pick.id)
      slip = hd(pick.shipping_slips)

      pick_pdf = write_pdf("pick.pdf", get(conn, ~p"/reports/total_picks/#{pick.id}"))
      bundle_pdf = write_pdf("bundle.pdf", get(conn, ~p"/reports/total_picks/#{pick.id}/bundle"))
      work_pdf = write_pdf("work_order.pdf", get(conn, ~p"/reports/work_orders/#{slip.id}"))

      assert byte_size(bundle_pdf) > byte_size(pick_pdf)
      assert byte_size(work_pdf) > 1000
    end

    @tag timeout: 120_000
    test "50 伝票を束ねた PDF を 30 秒以内に生成できる", %{conn: conn, scope: scope} do
      client = client_fixture()
      item = shipping_item_fixture()

      base = %{
        client_id: client.id,
        shipping_item_id: item.id,
        scheduled_ship_date: ~D[2026-11-20]
      }

      for n <- 1..50 do
        allocated_slip_fixture(Map.put(base, :client_slip_no, "PO-#{n}"),
          scope: scope,
          lots: [{"2026-12-20", 20}, {"2027-0#{rem(n, 9) + 1}-01", 16}]
        )
      end

      {:ok, [pick]} =
        TotalPicks.create_total_picks(scope, ~D[2026-11-20], [
          {client.id, item.inventory_maker_id}
        ])

      {micros, conn} =
        :timer.tc(fn -> get(conn, ~p"/reports/total_picks/#{pick.id}/bundle") end)

      write_pdf("bundle50.pdf", conn)
      IO.puts("50 伝票の束ね PDF: #{div(micros, 1000)} ms")
      assert micros < 30_000_000
    end
  end
end
