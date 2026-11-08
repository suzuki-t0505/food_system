defmodule FoodShipWeb.ReportController do
  @moduledoc """
  帳票(PDF)のダウンロード。LiveView ではなく Controller で配信する。

  認可は HTTP plug(`require_authenticated_staff_user`)と、アクション内の
  `Permission.authorize/2`（`manage_total_picks`）の二重。帳票は**都度生成して保存しない**。

    * `total_pick/2` - トータルピック表（ピック表 → 仕分け表）
    * `total_pick_bundle/2` - ピック表 → 仕分け表 → 所属伝票の作業指示書（`slip_no` 昇順）
    * `work_order/2` - 作業指示書（`allocated` / `packed` の伝票）

  出力できるのは `issued` のピックだけ。`outdated`（要再発行）・`cancelled` は詳細画面へ戻す。
  """

  use FoodShipWeb, :controller
  use FoodShip.Utils.Logger

  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.{Pdf, Permission}
  alias FoodShipWeb.ReportHTML

  @printable_slip_statuses [:allocated, :packed]

  def total_pick(conn, %{"id" => id}) do
    with_printable_pick(conn, id, fn conn, pick ->
      summary = TotalPicks.summarize(pick)
      html = render_html(&ReportHTML.total_pick_document/1, %{pick: pick, summary: summary})
      send_pdf(conn, html, TotalPick.pick_no_label(pick))
    end)
  end

  def total_pick_bundle(conn, %{"id" => id}) do
    with_printable_pick(conn, id, fn conn, pick ->
      summary = TotalPicks.summarize(pick)

      html =
        render_html(&ReportHTML.bundle_document/1, %{
          pick: pick,
          summary: summary,
          slips: pick.shipping_slips
        })

      send_pdf(conn, html, TotalPick.pick_no_label(pick))
    end)
  end

  def work_order(conn, %{"id" => id}) do
    case Permission.authorize(conn.assigns.current_scope.user, :manage_total_picks) do
      :ok -> print_work_order(conn, ShippingSlips.get_shipping_slip!(id))
      {:error, :forbidden} -> forbidden(conn)
    end
  end

  defp print_work_order(conn, %ShippingSlip{status: status} = slip)
       when status in @printable_slip_statuses do
    html = render_html(&ReportHTML.work_order_document/1, %{slip: slip, pick: slip.total_pick})
    send_pdf(conn, html, ShippingSlip.slip_no_label(slip))
  end

  defp print_work_order(conn, slip) do
    conn
    |> put_flash(:error, "作業指示書は、引当済み・梱包完了の伝票だけ出力できます。")
    |> redirect(to: ~p"/shipping_slips?#{%{date: Date.to_iso8601(slip.scheduled_ship_date)}}")
  end

  # `issued` のピックだけ出力できる。それ以外は詳細画面へ戻して理由を伝える
  defp with_printable_pick(conn, id, fun) do
    case Permission.authorize(conn.assigns.current_scope.user, :manage_total_picks) do
      :ok -> print_pick(conn, TotalPicks.get_total_pick!(id), fun)
      {:error, :forbidden} -> forbidden(conn)
    end
  end

  defp print_pick(conn, %TotalPick{status: :issued} = pick, fun), do: fun.(conn, pick)

  defp print_pick(conn, %TotalPick{status: :outdated} = pick, _fun) do
    conn
    |> put_flash(:error, "要再発行です。再発行してから出力してください。")
    |> redirect(to: ~p"/total_picks/#{pick.id}")
  end

  defp print_pick(conn, %TotalPick{status: :cancelled} = pick, _fun) do
    conn
    |> put_flash(:error, "取消済みのトータルピックは出力できません。")
    |> redirect(to: ~p"/total_picks/#{pick.id}")
  end

  defp forbidden(conn) do
    conn |> put_flash(:error, "権限がありません。") |> redirect(to: ~p"/")
  end

  # HEEx の関数コンポーネントを HTML 文字列にする
  defp render_html(component, assigns) do
    assigns |> component.() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  defp send_pdf(conn, html, name) do
    case Pdf.render(html) do
      {:ok, pdf} ->
        conn
        |> put_resp_content_type("application/pdf")
        |> put_resp_header("content-disposition", ~s(inline; filename="#{name}.pdf"))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, pdf)

      {:error, :busy} ->
        Logger.warning("PDF の生成が混み合っています。", :other, %{report: name})

        conn
        |> put_status(:service_unavailable)
        |> text("PDF の生成が混み合っています。しばらくしてからやり直してください。")

      {:error, reason} ->
        Logger.error("PDF を生成できませんでした。", :other, %{report: name, reason: inspect(reason)})

        conn
        |> put_status(:internal_server_error)
        |> text("PDF を生成できませんでした。")
    end
  end
end
