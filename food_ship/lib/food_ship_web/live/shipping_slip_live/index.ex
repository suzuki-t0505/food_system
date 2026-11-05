defmodule FoodShipWeb.ShippingSlipLive.Index do
  @moduledoc """
  作業画面(出荷予定日別の伝票一覧)。全ロールが参照でき、操作は `staff` 以上。

  出荷予定日ごとのタブ(残件数 = `pending` / `allocated` / `shortage` の合計)と、状態フィルタ
  (すべて／未梱包のみ／在庫不足のみ)を持つ。各伝票には、引当ロットの「期限日 × 個数」を表示する。
  `pending` の行には、引当エラーの種別(一時／恒久)と最終試行日時を表示する。

  在庫 API を呼ぶ操作(再引当・取消)は `Task` ＋ `handle_info` で非同期に行い、実行中の伝票の
  行・ボタンを無効化する(`busy`)。操作ログは結果を受ける `handle_info` の成功節で出す。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.SlipComponents

  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.Utils.{ConvertDatetime, Permission}
  alias FoodShipWeb.SlipMessages

  @filters %{"all" => :all, "unpacked" => :unpacked, "shortage" => :shortage}
  @filter_options [all: "すべて", unpacked: "未梱包のみ", shortage: "在庫不足のみ"]
  # 作業画面のタブに出す、過去の出荷予定日の範囲(日)
  @past_days 7

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        作業画面
        <:actions>
          <.link
            :if={@can_manage}
            navigate={~p"/shipping_slips/new"}
            class="btn btn-primary"
            id="new-shipping-slip"
          >
            伝票を登録する
          </.link>
        </:actions>
      </.header>

      <div
        :if={@can_manage and !@warehouse_configured}
        id="warehouse-warning"
        role="alert"
        class="alert alert-warning"
      >
        対象倉庫が設定されていません。管理者に連絡してください。
      </div>

      <div role="tablist" class="tabs tabs-box flex-wrap" id="ship-date-tabs">
        <.link
          :for={tab <- @tabs}
          role="tab"
          patch={tab_path(tab.date, @filter)}
          id={"tab-#{tab.date}"}
          class={["tab", tab.date == @date && "tab-active"]}
        >
          {Calendar.strftime(tab.date, "%m/%d")} (残{tab.remaining}件)
        </.link>
        <form phx-change="select_date" id="select-date-form" class="ml-2 flex items-center">
          <input
            type="date"
            name="date"
            value={@date}
            class="input input-sm"
            aria-label="出荷予定日"
          />
        </form>
      </div>

      <div class="join" id="status-filter">
        <.link
          :for={{filter, label} <- filter_options()}
          patch={tab_path(@date, filter)}
          id={"filter-#{filter}"}
          class={["join-item btn btn-sm", filter == @filter && "btn-active"]}
        >
          {label}
        </.link>
      </div>

      <div class="overflow-x-auto">
        <table class="table" id="shipping-slips">
          <thead>
            <tr>
              <th>伝票番号</th>
              <th>発注元</th>
              <th>商品</th>
              <th class="text-right">件数</th>
              <th class="text-right">箱数</th>
              <th class="text-right">バラ数</th>
              <th>ピッキング対象(期限日 × 個数)</th>
              <th>状態</th>
              <th :if={@can_manage}></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={slip <- @slips}
              id={"slip-#{slip.id}"}
              class={[
                row_class(slip, @has_packed),
                MapSet.member?(@busy, slip.id) && "opacity-60"
              ]}
            >
              <td class="whitespace-nowrap">
                {ShippingSlip.slip_no_label(slip)}
                <span :if={slip.client_slip_no} class="block text-xs">{slip.client_slip_no}</span>
              </td>
              <td>{slip.client.client_name}</td>
              <td>{slip.shipping_item.item_code} {slip.shipping_item.item_name}</td>
              <td class="text-right">{slip.order_count}</td>
              <td class="text-right">{slip.box_count}</td>
              <td class="text-right">{slip.total_piece_qty}</td>
              <td><.allocated_lots lots={slip.allocated_lots} /></td>
              <td>
                <.status_badge status={slip.status} />
                <span
                  :if={@has_packed and ShippingSlip.unpacked?(slip)}
                  class="badge badge-outline badge-sm whitespace-nowrap"
                >
                  追加
                </span>
                <span :if={slip.status == :shortage} class="block text-xs text-error">
                  不足 {slip.shortage_pieces} 個
                </span>
                <span :if={slip.status == :pending} class="block text-xs" id={"pending-#{slip.id}"}>
                  {SlipMessages.pending_message(slip)}
                  <span :if={slip.allocation_attempted_at} class="block">
                    最終試行: {ConvertDatetime.format_jst(slip.allocation_attempted_at)}
                  </span>
                </span>
                <span :if={MapSet.member?(@busy, slip.id)} class="block text-xs">処理中…</span>
              </td>
              <td :if={@can_manage} class="space-x-1 text-right whitespace-nowrap">
                <button
                  :if={slip.status in [:pending, :shortage]}
                  phx-click="reallocate"
                  phx-value-id={slip.id}
                  disabled={MapSet.member?(@busy, slip.id)}
                  class="btn btn-sm"
                  id={"reallocate-#{slip.id}"}
                >
                  再引当
                </button>
                <.link
                  :if={ShippingSlip.unpacked?(slip)}
                  navigate={~p"/shipping_slips/#{slip.id}/edit"}
                  class={["btn btn-sm", MapSet.member?(@busy, slip.id) && "btn-disabled"]}
                  id={"edit-#{slip.id}"}
                >
                  数量変更
                </.link>
                <button
                  :if={ShippingSlip.unpacked?(slip)}
                  phx-click="cancel"
                  phx-value-id={slip.id}
                  disabled={MapSet.member?(@busy, slip.id)}
                  data-confirm="この伝票を取り消します。在庫の引当も解除されます。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"cancel-#{slip.id}"}
                >
                  取消
                </button>
              </td>
            </tr>
            <tr :if={@slips == []}>
              <td colspan="9" class="text-center text-sm" id="no-slips">該当する伝票はありません。</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:busy, MapSet.new())
     |> assign(:can_manage, Permission.can?(user, :manage_shipping_slips))
     |> assign(:warehouse_configured, ShippingSlips.warehouse_configured?())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    today = ConvertDatetime.today_jst()
    tabs = tabs(today, parse_date(params["date"]))
    date = selected_date(params["date"], tabs, today)

    {:noreply,
     socket
     |> assign(:tabs, tabs)
     |> assign(:date, date)
     |> assign(:filter, Map.get(@filters, params["filter"], :all))
     |> assign_slips()}
  end

  @impl true
  def handle_event("select_date", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:noreply, push_patch(socket, to: tab_path(date, socket.assigns.filter))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reallocate", %{"id" => id}, socket),
    do: start_action(socket, id, :allocate, &ShippingSlips.allocate_shipping_slip/2)

  def handle_event("cancel", %{"id" => id}, socket),
    do: start_action(socket, id, :cancel, &ShippingSlips.cancel_shipping_slip/2)

  @impl true
  def handle_info({:slip_result, action, id, result}, socket) do
    socket = update(socket, :busy, &MapSet.delete(&1, id))
    {kind, message} = result_message(action, result)

    case result do
      {:ok, %ShippingSlip{} = slip} -> OperationLog.info(socket, message, :update, slip)
      {:ok, %ShippingSlip{} = slip, _info} -> OperationLog.info(socket, message, :update, slip)
      _ -> :ok
    end

    # 失敗でも、他の操作で状態が変わっている可能性があるので、伝票と残件数を読み直す
    {:noreply, socket |> put_flash(kind, message) |> refresh_tabs() |> assign_slips()}
  end

  # 在庫 API を呼ぶ操作を Task で始める。権限は、ボタンの表示とは別にここで検査する
  defp start_action(socket, id, action, fun) do
    cond do
      !socket.assigns.can_manage ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      MapSet.member?(socket.assigns.busy, id) ->
        {:noreply, socket}

      true ->
        slip = ShippingSlips.get_shipping_slip!(id)
        pid = self()
        scope = socket.assigns.current_scope

        Task.start(fn -> send(pid, {:slip_result, action, slip.id, fun.(scope, slip)}) end)

        {:noreply, update(socket, :busy, &MapSet.put(&1, slip.id))}
    end
  end

  defp result_message(:allocate, result), do: SlipMessages.allocation_result(result)

  defp result_message(:cancel, {:ok, _slip}), do: {:info, "伝票を取り消しました。"}
  defp result_message(:cancel, {:error, reason}), do: {:error, SlipMessages.error_message(reason)}

  defp assign_slips(socket) do
    %{date: date, filter: filter} = socket.assigns

    socket
    |> assign(:slips, ShippingSlips.list_shipping_slips(date, filter))
    |> assign(:has_packed, ShippingSlips.any_packed?(date))
  end

  defp refresh_tabs(socket),
    do: assign(socket, :tabs, tabs(ConvertDatetime.today_jst(), socket.assigns.date))

  # 出荷予定日のタブ。今日の少し前から先の日付と、表示中の日付(範囲外でも出す)
  defp tabs(today, selected) do
    from = Date.add(today, -@past_days)

    summaries = ShippingSlips.summarize_ship_dates(Enum.min([from, selected || from], Date))

    summaries
    |> Enum.filter(&(Date.compare(&1.date, from) != :lt or &1.date == selected))
    |> ensure_tab(selected)
  end

  defp ensure_tab(tabs, nil), do: tabs

  defp ensure_tab(tabs, date) do
    if Enum.any?(tabs, &(&1.date == date)) do
      tabs
    else
      Enum.sort_by([%{date: date, remaining: 0} | tabs], & &1.date, Date)
    end
  end

  defp selected_date(param, tabs, today) do
    parse_date(param) ||
      case Enum.find(tabs, &(Date.compare(&1.date, today) != :lt)) do
        %{date: date} -> date
        nil -> today
      end
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp tab_path(date, filter) do
    ~p"/shipping_slips?#{%{date: Date.to_iso8601(date), filter: filter}}"
  end

  defp filter_options, do: @filter_options

  # 梱包完了後に届いた追加伝票(未梱包)をハイライトする。梱包済みはグレーアウト
  defp row_class(%ShippingSlip{status: :packed}, _has_packed), do: "opacity-50"

  defp row_class(%ShippingSlip{} = slip, true) do
    if ShippingSlip.unpacked?(slip), do: "bg-warning/20", else: nil
  end

  defp row_class(_slip, _has_packed), do: nil
end
