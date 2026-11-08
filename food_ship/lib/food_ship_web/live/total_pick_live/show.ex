defmodule FoodShipWeb.TotalPickLive.Show do
  @moduledoc """
  トータルピックの詳細（全ロール参照）。ピック明細（商品 × 期限日の合算）・仕分け内訳・紐づく
  伝票の一覧を表示する。PDF の出力・再発行・取消は `staff` 以上。

  再発行・取消は DB だけの更新なので `Task` にせず同期で行う。要再発行（`outdated`）のピックは、
  再発行するまで PDF を出力できない。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.SlipComponents

  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.TotalPicks
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.{ConvertDatetime, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        トータルピック {TotalPick.pick_no_label(@pick)}
        <:subtitle>
          第{@pick.revision}版 <.pick_status_badge status={@pick.status} class="ml-2" />
        </:subtitle>
        <:actions>
          <.link navigate={~p"/total_picks"} class="btn" id="to-total-picks">一覧へ</.link>
        </:actions>
      </.header>

      <dl class="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4" id="pick-summary">
        <div>
          <dt class="font-semibold">出荷予定日</dt>
          <dd>{@pick.scheduled_ship_date}</dd>
        </div>
        <div>
          <dt class="font-semibold">発注元</dt>
          <dd>{@pick.client.client_name}</dd>
        </div>
        <div>
          <dt class="font-semibold">メーカー</dt>
          <dd>{@pick.maker_name}</dd>
        </div>
        <div>
          <dt class="font-semibold">発行</dt>
          <dd>
            {ConvertDatetime.format_jst(@pick.issued_at)}
            <span class="block">{@pick.issued_by_user.email}</span>
          </dd>
        </div>
      </dl>

      <div :if={@can_pick} class="flex flex-wrap gap-2" id="pick-actions">
        <.link
          :if={@pick.status == :issued}
          href={~p"/reports/total_picks/#{@pick.id}"}
          target="_blank"
          class="btn btn-primary"
          id="download-pick"
        >
          ピック表 PDF
        </.link>
        <.link
          :if={@pick.status == :issued}
          href={~p"/reports/total_picks/#{@pick.id}/bundle"}
          target="_blank"
          class="btn btn-primary"
          id="download-bundle"
        >
          ピック表＋作業指示書 PDF
        </.link>
        <button
          :if={@pick.status == :outdated and @pick.shipping_slips != []}
          phx-click="reissue"
          class="btn btn-warning"
          id="reissue-pick"
        >
          再発行
        </button>
        <button
          :if={@pick.status in [:issued, :outdated]}
          phx-click="cancel"
          data-confirm="トータルピックを取り消します。伝票は未ピックに戻ります。よろしいですか?"
          class="btn btn-error btn-soft"
          id="cancel-pick"
        >
          取消
        </button>
      </div>

      <div :if={@pick.status == :outdated} role="alert" class="alert alert-warning" id="outdated-note">
        紐づく伝票が外れたため、要再発行です。再発行するまで PDF は出力できません。
      </div>

      <h2 class="text-lg font-semibold">ピック明細（商品 × 期限日）</h2>
      <div class="overflow-x-auto">
        <table class="table" id="pick-lines">
          <thead>
            <tr>
              <th>商品</th>
              <th>期限日</th>
              <th class="text-right">バラ数</th>
              <th class="text-right">件数</th>
              <th class="text-right">箱数</th>
              <th>仕分け（伝票番号 × 数量）</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={line <- @summary.lines}>
              <td>{line.item_code} {line.item_name}</td>
              <td class="whitespace-nowrap">{expiration(line.expiration_date)}</td>
              <td class="text-right">{line.pieces}</td>
              <td class="text-right">{line.order_count}</td>
              <td class="text-right">{line.box_count}</td>
              <td>
                <span :for={entry <- line.slips} class="mr-2 inline-block whitespace-nowrap">
                  {slip_no_text(entry.slip_no)} × {entry.pieces}
                </span>
              </td>
            </tr>
            <tr :if={@summary.lines != []} class="font-semibold" id="pick-totals">
              <td colspan="2">合計</td>
              <td class="text-right">{@summary.totals.pieces}</td>
              <td class="text-right">{@summary.totals.order_count}</td>
              <td class="text-right">{@summary.totals.box_count}</td>
              <td></td>
            </tr>
            <tr :if={@summary.lines == []}>
              <td colspan="6" class="text-center text-sm">紐づく伝票はありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="text-lg font-semibold">紐づく伝票</h2>
      <div class="overflow-x-auto">
        <table class="table" id="pick-slips">
          <thead>
            <tr>
              <th>伝票番号</th>
              <th>商品</th>
              <th class="text-right">件数</th>
              <th class="text-right">箱数</th>
              <th class="text-right">バラ数</th>
              <th>状態</th>
              <th :if={@can_pick}></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={slip <- @pick.shipping_slips} id={"pick-slip-#{slip.id}"}>
              <td class="whitespace-nowrap">{ShippingSlip.slip_no_label(slip)}</td>
              <td>{slip.shipping_item.item_code} {slip.shipping_item.item_name}</td>
              <td class="text-right">{slip.order_count}</td>
              <td class="text-right">{slip.box_count}</td>
              <td class="text-right">{slip.total_piece_qty}</td>
              <td><.status_badge status={slip.status} /></td>
              <td :if={@can_pick} class="text-right">
                <.link
                  href={~p"/reports/work_orders/#{slip.id}"}
                  target="_blank"
                  class="btn btn-sm"
                  id={"work-order-#{slip.id}"}
                >
                  作業指示書
                </.link>
              </td>
            </tr>
            <tr :if={@pick.shipping_slips == []}>
              <td colspan="7" class="text-center text-sm">紐づく伝票はありません。</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:pick_id, id)
     |> assign(:can_pick, Permission.can?(socket.assigns.current_scope.user, :manage_total_picks))
     |> load()}
  end

  @impl true
  def handle_event("reissue", _params, socket) do
    act(socket, &TotalPicks.reissue_total_pick/2, "トータルピックを再発行しました。")
  end

  def handle_event("cancel", _params, socket) do
    act(socket, &TotalPicks.cancel_total_pick/2, "トータルピックを取り消しました。")
  end

  # 権限は、ボタンの表示とは別にここで検査する（Context でも検査する）
  defp act(socket, fun, success_message) do
    if socket.assigns.can_pick do
      case fun.(socket.assigns.current_scope, socket.assigns.pick) do
        {:ok, pick} ->
          OperationLog.info(socket, success_message, :update, pick)
          {:noreply, socket |> flash_once(:info, success_message) |> load()}

        {:error, reason} ->
          {:noreply, socket |> flash_once(:error, error_message(reason)) |> load()}
      end
    else
      {:noreply, flash_once(socket, :error, error_message(:forbidden))}
    end
  end

  defp load(socket) do
    pick = TotalPicks.get_total_pick!(socket.assigns.pick_id)

    socket
    |> assign(:page_title, TotalPick.pick_no_label(pick))
    |> assign(:pick, pick)
    |> assign(:summary, TotalPicks.summarize(pick))
  end

  # 前の操作のメッセージを消してから、最新の結果だけを表示する
  defp flash_once(socket, kind, message), do: socket |> clear_flash() |> put_flash(kind, message)

  defp error_message(:forbidden), do: "権限がありません。"
  defp error_message(:invalid_status), do: "このトータルピックの状態では実行できません。"
  defp error_message(:has_packed_slips), do: "梱包済みの伝票があるため、取り消せません。"
  defp error_message(_reason), do: "実行できませんでした。"

  defp expiration(date), do: FoodShip.ShippingSlips.SlipAllocatedLot.expiration_label(date)

  defp slip_no_text(slip_no), do: ShippingSlip.format_slip_no(slip_no)
end
