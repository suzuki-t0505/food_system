defmodule FoodShipWeb.ShippingSlipLive.Index do
  @moduledoc """
  作業画面(出荷予定日別の伝票一覧)。全ロールが参照でき、操作は `staff` 以上。

  出荷予定日ごとのタブ(残件数 = `pending` / `allocated` / `shortage` の合計)と、状態フィルタ
  (すべて／未梱包のみ／在庫不足のみ)を持つ。各伝票には、引当ロットの「期限日 × 個数」を表示する。
  `pending` の行には、引当エラーの種別(一時／恒久)と最終試行日時を表示する。

  梱包完了(在庫側の出庫確定)と箱数の修正は `staff` 以上。箱数は梱包前の伝票でインライン編集できる
  (在庫数には影響しない)。在庫 API を呼ぶ操作(再引当・取消・梱包完了)は `Task` ＋ `handle_info` で非同期に行い、実行中の伝票の
  行・ボタンを無効化する(`busy`)。操作ログは結果を受ける `handle_info` の成功節で出す。

  一括処理(F-S5・F-S8): 「一括再引当」(全日付の `pending` / `shortage`。恒久エラーの行は対象外)と、
  `allocated` の行を選択しての「一括梱包完了」は、`Bulk.run/4` を `Task` で実行して 1 件ずつ順に処理し、
  進捗パネル(`bulk`)に処理済み件数／全件と伝票ごとの成否を出す。実行中(`bulk_running`)は、一括の
  ボタンと対象行(`busy`)を無効化して二重実行を防ぐ。対象行の表示は、全件の処理後にまとめて更新する。
  CSV の取込は別画面(`ShippingSlipLive.Import`)。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.SlipComponents

  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.{Bulk, ShippingSlip}
  alias FoodShip.Utils.{ConvertDatetime, Permission}
  alias FoodShipWeb.SlipMessages

  @filters %{"all" => :all, "unpacked" => :unpacked, "shortage" => :shortage}
  @filter_options [all: "すべて", unpacked: "未梱包のみ", shortage: "在庫不足のみ"]
  # 作業画面のタブに出す、過去の出荷予定日の範囲(日)
  @past_days 7
  @interrupted_message "一括処理が中断しました。もう一度実行してください(処理済みの伝票はそのままです)。"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        作業画面
        <:actions>
          <.link
            :if={@can_manage}
            navigate={~p"/shipping_slips/import"}
            class="btn"
            id="import-csv"
          >
            CSV を取り込む
          </.link>
          <button
            :if={@can_manage}
            type="button"
            phx-click="reallocate_all"
            disabled={@bulk_running or !@warehouse_configured}
            data-confirm="引当待ち・在庫不足の伝票を、出荷予定日の早い順に再引当します。よろしいですか?"
            class="btn"
            id="reallocate-all"
          >
            一括再引当
          </button>
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

      <div :if={@bulk} id="bulk-panel" class="space-y-3 rounded-box border border-base-300 p-4">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">{bulk_title(@bulk.kind)}</h2>
          <button
            :if={!@bulk_running}
            type="button"
            phx-click="close_bulk"
            class="btn btn-xs btn-ghost"
            id="close-bulk"
          >
            閉じる
          </button>
        </div>
        <.bulk_progress
          id="bulk-progress"
          label={bulk_title(@bulk.kind)}
          done={@bulk.done}
          total={@bulk.total}
        />
        <p :if={@bulk.summary} id="bulk-summary" class="font-semibold">{@bulk.summary}</p>
        <.bulk_results id="bulk-results" rows={@streams.bulk_results} />
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

      <div :if={@can_pack} class="flex items-center gap-2" id="bulk-pack-bar">
        <button
          type="button"
          phx-click="pack_selected"
          disabled={MapSet.size(@selected) == 0 or @bulk_running}
          data-confirm={"選択した #{MapSet.size(@selected)} 件を梱包完了にします。在庫が減算され、元に戻せません。よろしいですか?"}
          class="btn btn-sm btn-primary"
          id="pack-selected"
        >
          選択した伝票を梱包完了にする({MapSet.size(@selected)} 件)
        </button>
      </div>

      <div class="overflow-x-auto">
        <table class="table" id="shipping-slips">
          <thead>
            <tr>
              <th :if={@can_pack}>
                <input
                  type="checkbox"
                  id="select-all"
                  phx-click="toggle_select_all"
                  checked={all_selected?(@selected, @selectable_ids)}
                  disabled={@bulk_running or @selectable_ids == []}
                  class="checkbox checkbox-sm"
                  aria-label="梱包前の引当済みの伝票をすべて選択"
                />
              </th>
              <th>伝票番号</th>
              <th>発注元</th>
              <th>商品</th>
              <th class="text-right">件数</th>
              <th class="text-right">箱数</th>
              <th class="text-right">バラ数</th>
              <th>ピッキング対象(期限日 × 個数)</th>
              <th>状態</th>
              <th :if={@can_manage or @can_pack}></th>
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
              <td :if={@can_pack}>
                <input
                  :if={slip.status == :allocated}
                  type="checkbox"
                  id={"select-#{slip.id}"}
                  phx-click="toggle_select"
                  phx-value-id={slip.id}
                  checked={MapSet.member?(@selected, slip.id)}
                  disabled={@bulk_running or MapSet.member?(@busy, slip.id)}
                  class="checkbox checkbox-sm"
                  aria-label="選択"
                />
              </td>
              <td class="whitespace-nowrap">
                {ShippingSlip.slip_no_label(slip)}
                <span :if={slip.client_slip_no} class="block text-xs">{slip.client_slip_no}</span>
              </td>
              <td>{slip.client.client_name}</td>
              <td>{slip.shipping_item.item_code} {slip.shipping_item.item_name}</td>
              <td class="text-right">{slip.order_count}</td>
              <td class="text-right">
                <form
                  :if={@can_pack and ShippingSlip.unpacked?(slip)}
                  id={"box-form-#{slip.id}"}
                  phx-submit="update_box_count"
                  class="flex items-center justify-end gap-1"
                >
                  <input type="hidden" name="slip_id" value={slip.id} />
                  <input
                    type="number"
                    name="box_count"
                    value={slip.box_count}
                    min="1"
                    class="input input-sm w-16 text-right"
                    aria-label="箱数"
                    disabled={MapSet.member?(@busy, slip.id)}
                  />
                  <button
                    class="btn btn-sm btn-ghost"
                    disabled={MapSet.member?(@busy, slip.id)}
                    id={"update-box-count-#{slip.id}"}
                  >
                    更新
                  </button>
                </form>
                <span :if={!(@can_pack and ShippingSlip.unpacked?(slip))}>{slip.box_count}</span>
              </td>
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
                <span :if={slip.status == :packed} class="block text-xs">
                  {ConvertDatetime.format_jst(slip.packed_at)}
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
              <td :if={@can_manage or @can_pack} class="space-x-1 text-right whitespace-nowrap">
                <button
                  :if={@can_pack and slip.status == :allocated}
                  phx-click="pack"
                  phx-value-id={slip.id}
                  disabled={MapSet.member?(@busy, slip.id)}
                  data-confirm="梱包完了にします。在庫が減算され、元に戻せません。よろしいですか?"
                  class="btn btn-sm btn-primary"
                  id={"pack-#{slip.id}"}
                >
                  梱包完了
                </button>
                <button
                  :if={@can_manage and slip.status in [:pending, :shortage]}
                  phx-click="reallocate"
                  phx-value-id={slip.id}
                  disabled={MapSet.member?(@busy, slip.id)}
                  class="btn btn-sm"
                  id={"reallocate-#{slip.id}"}
                >
                  再引当
                </button>
                <.link
                  :if={@can_manage and ShippingSlip.unpacked?(slip)}
                  navigate={~p"/shipping_slips/#{slip.id}/edit"}
                  class={["btn btn-sm", MapSet.member?(@busy, slip.id) && "btn-disabled"]}
                  id={"edit-#{slip.id}"}
                >
                  数量変更
                </.link>
                <button
                  :if={@can_manage and ShippingSlip.unpacked?(slip)}
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
              <td colspan="10" class="text-center text-sm" id="no-slips">該当する伝票はありません。</td>
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
     |> assign(:bulk, nil)
     |> assign(:bulk_running, false)
     |> assign(:selected, MapSet.new())
     |> assign(:selectable_ids, [])
     |> stream(:bulk_results, [])
     |> assign(:can_manage, Permission.can?(user, :manage_shipping_slips))
     |> assign(:can_pack, Permission.can?(user, :pack_shipping_slips))
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

  def handle_event("reallocate", %{"id" => id}, socket) do
    start_action(
      socket,
      id,
      :manage_shipping_slips,
      :allocate,
      &ShippingSlips.allocate_shipping_slip/2
    )
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    start_action(
      socket,
      id,
      :manage_shipping_slips,
      :cancel,
      &ShippingSlips.cancel_shipping_slip/2
    )
  end

  def handle_event("reallocate_all", _params, socket) do
    cond do
      !socket.assigns.can_manage ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      socket.assigns.bulk_running ->
        {:noreply, socket}

      true ->
        case ShippingSlips.list_reallocation_targets() do
          [] ->
            {:noreply, flash_once(socket, :info, "再引当の対象がありません。")}

          slips ->
            {:noreply,
             start_bulk(socket, :reallocate, slips, &ShippingSlips.allocate_shipping_slip/2)}
        end
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    %{can_pack: can_pack, bulk_running: running, selectable_ids: selectable} = socket.assigns

    if can_pack and !running and id in selectable and !MapSet.member?(socket.assigns.busy, id) do
      {:noreply, update(socket, :selected, &toggle(&1, id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_select_all", _params, socket) do
    %{can_pack: can_pack, bulk_running: running, selectable_ids: selectable} = socket.assigns

    if can_pack and !running do
      all = MapSet.new(selectable)

      selected = if MapSet.equal?(socket.assigns.selected, all), do: MapSet.new(), else: all
      {:noreply, assign(socket, :selected, selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pack_selected", _params, socket) do
    cond do
      !socket.assigns.can_pack ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      socket.assigns.bulk_running ->
        {:noreply, socket}

      true ->
        slips =
          socket.assigns.selected
          |> MapSet.to_list()
          |> ShippingSlips.list_slips_by_ids()
          |> Enum.filter(&(&1.status == :allocated))
          |> Enum.reject(&MapSet.member?(socket.assigns.busy, &1.id))

        if slips == [] do
          {:noreply, flash_once(socket, :error, "梱包完了にできる伝票が選択されていません。")}
        else
          socket =
            socket
            |> assign(:selected, MapSet.new())
            |> start_bulk(:pack, slips, &ShippingSlips.pack_shipping_slip/2)

          {:noreply, socket}
        end
    end
  end

  def handle_event("close_bulk", _params, socket) do
    if socket.assigns.bulk_running do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:bulk, nil) |> stream(:bulk_results, [], reset: true)}
    end
  end

  def handle_event("pack", %{"id" => id}, socket) do
    start_action(socket, id, :pack_shipping_slips, :pack, &ShippingSlips.pack_shipping_slip/2)
  end

  # 箱数の修正は DB だけの更新なので、Task にせず同期で行う
  def handle_event("update_box_count", %{"slip_id" => id, "box_count" => box_count}, socket) do
    cond do
      !socket.assigns.can_pack ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      MapSet.member?(socket.assigns.busy, id) ->
        {:noreply, socket}

      true ->
        slip = ShippingSlips.get_shipping_slip!(id)
        result = ShippingSlips.update_box_count(socket.assigns.current_scope, slip, box_count)
        {:noreply, socket |> box_count_result(result) |> assign_slips()}
    end
  end

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
    {:noreply, socket |> flash_once(kind, message) |> refresh_tabs() |> assign_slips()}
  end

  def handle_info({:bulk_progress, ref, slip, result}, socket) do
    case socket.assigns.bulk do
      %{ref: ^ref} -> {:noreply, record_bulk_progress(socket, slip, result)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:bulk_done, ref}, socket) do
    case socket.assigns.bulk do
      %{ref: ^ref, monitor: monitor, kind: kind, counts: counts} ->
        Process.demonitor(monitor, [:flush])
        summary = SlipMessages.bulk_summary(bulk_operation(kind), counts)
        OperationLog.info(socket, "#{bulk_title(kind)}を終えました。#{summary}", :update, counts)

        socket = update(socket, :bulk, &%{&1 | ref: nil, monitor: nil, summary: summary})
        {:noreply, socket |> release_bulk() |> flash_once(:info, summary)}

      _ ->
        {:noreply, socket}
    end
  end

  # Task が最後まで進まずに終了した(完了通知より先に来た場合のみ異常終了)。
  # 処理されなかった伝票は `pending` / `allocated` のまま残るので、やり直せる
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, socket) do
    case socket.assigns.bulk do
      %{monitor: ^monitor} ->
        socket = update(socket, :bulk, &%{&1 | ref: nil, monitor: nil})
        {:noreply, socket |> release_bulk() |> flash_once(:error, @interrupted_message)}

      _ ->
        {:noreply, socket}
    end
  end

  # 一括処理を Task で始める。対象は全件を `busy`(行・ボタンの無効化)にし、全件の処理後にまとめて解放する。
  # 権限と二重実行は、呼び出し側(イベント処理)で検査する
  defp start_bulk(socket, kind, slips, fun) do
    ref = make_ref()
    pid = self()
    scope = socket.assigns.current_scope

    notify = fn _index, _total, slip, result ->
      send(pid, {:bulk_progress, ref, slip, result})
    end

    {:ok, task_pid} =
      Task.start(fn ->
        Bulk.run(scope, slips, fun, notify)
        send(pid, {:bulk_done, ref})
      end)

    ids = Enum.map(slips, & &1.id)

    socket
    |> update(:busy, fn busy -> Enum.reduce(ids, busy, &MapSet.put(&2, &1)) end)
    |> assign(:bulk_running, true)
    |> assign(:bulk, %{
      ref: ref,
      monitor: Process.monitor(task_pid),
      kind: kind,
      ids: ids,
      total: length(slips),
      done: 0,
      counts: %{},
      summary: nil
    })
    |> stream(:bulk_results, Enum.map(slips, &bulk_row(&1, nil, :waiting)), reset: true)
  end

  defp record_bulk_progress(socket, slip, result) do
    {kind, _text} = SlipMessages.bulk_outcome(result)
    log_bulk_success(socket, socket.assigns.bulk.kind, kind, result)

    socket
    |> update(:bulk, fn bulk ->
      %{bulk | done: bulk.done + 1, counts: Map.update(bulk.counts, kind, 1, &(&1 + 1))}
    end)
    |> stream_insert(:bulk_results, bulk_result_row(slip, nil, result))
  end

  # 操作ログは、失敗以外(状態が変わった伝票)について出す
  defp log_bulk_success(_socket, _operation, :error, _result), do: :ok

  defp log_bulk_success(socket, :reallocate, _kind, result) do
    {_kind, message} = SlipMessages.allocation_result(result)
    OperationLog.info(socket, message, :update, result_slip(result))
  end

  defp log_bulk_success(socket, :pack, _kind, result),
    do: OperationLog.info(socket, "梱包完了にしました。", :update, result_slip(result))

  defp result_slip({:ok, %ShippingSlip{} = slip}), do: slip
  defp result_slip({:ok, %ShippingSlip{} = slip, _info}), do: slip

  # 一括処理の終了後に、対象行の無効化を解いて、伝票と残件数を読み直す
  defp release_bulk(socket) do
    ids = socket.assigns.bulk.ids

    socket
    |> update(:busy, fn busy -> Enum.reduce(ids, busy, &MapSet.delete(&2, &1)) end)
    |> assign(:bulk_running, false)
    |> refresh_tabs()
    |> assign_slips()
  end

  defp bulk_operation(:reallocate), do: :allocate
  defp bulk_operation(:pack), do: :pack

  defp bulk_title(:reallocate), do: "一括再引当"
  defp bulk_title(:pack), do: "一括梱包完了"

  defp all_selected?(_selected, []), do: false
  defp all_selected?(selected, selectable), do: MapSet.size(selected) == length(selectable)

  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  # 在庫 API を呼ぶ操作を Task で始める。権限は、ボタンの表示とは別にここで検査する
  defp start_action(socket, id, permission, action, fun) do
    cond do
      !Permission.can?(socket.assigns.current_scope.user, permission) ->
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

  defp result_message(:pack, {:ok, _slip}), do: {:info, "梱包完了にしました。"}

  # 在庫側が停止している間は梱包完了を記録できない(allocated のまま)。復旧後にやり直す
  defp result_message(:pack, {:error, :connection}),
    do: {:error, "在庫システムに接続できませんでした。時間をおいて、もう一度梱包完了を行ってください。"}

  defp result_message(:pack, {:error, reason}), do: {:error, SlipMessages.error_message(reason)}

  defp result_message(:cancel, {:ok, _slip}), do: {:info, "伝票を取り消しました。"}
  defp result_message(:cancel, {:error, reason}), do: {:error, SlipMessages.error_message(reason)}

  defp box_count_result(socket, {:ok, slip}) do
    message = "箱数を更新しました。"
    OperationLog.info(socket, message, :update, slip)
    flash_once(socket, :info, message)
  end

  defp box_count_result(socket, {:error, %Ecto.Changeset{}}),
    do: flash_once(socket, :error, "箱数は 1 以上の整数で入力してください。")

  defp box_count_result(socket, {:error, reason}),
    do: flash_once(socket, :error, SlipMessages.error_message(reason))

  # 前の操作のメッセージ(別の種類を含む)を消してから、最新の結果だけを表示する
  defp flash_once(socket, kind, message), do: socket |> clear_flash() |> put_flash(kind, message)

  defp assign_slips(socket) do
    %{date: date, filter: filter} = socket.assigns

    slips = ShippingSlips.list_shipping_slips(date, filter)
    selectable = for slip <- slips, slip.status == :allocated, do: slip.id

    socket
    |> assign(:slips, slips)
    |> assign(:has_packed, ShippingSlips.any_packed?(date))
    |> assign(:selectable_ids, selectable)
    |> update(:selected, &MapSet.intersection(&1, MapSet.new(selectable)))
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
