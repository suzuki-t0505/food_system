defmodule FoodShipWeb.ShippingSlipLive.Import do
  @moduledoc """
  CSV 一括取込(functional-design §6.1)。`staff` 以上。

  1. CSV(UTF-8・見出し行あり・1 行 = 1 伝票)をアップロードする
  2. 検証(`ShippingSlips.import_csv/2`)。**1 行でもエラーがあれば何も保存せず**、行番号つきの
     エラー一覧を表示する。検証と保存はこの画面のプロセスで行い、保存は引当より前に完了する
  3. 保存した全行を、出荷予定日の早い順 → ファイル順に `Task` で 1 件ずつ引当する。
     `handle_info` で進捗(処理済み件数／全件)と行ごとの結果を更新する。在庫不足は `shortage` で保存される

  Task が途中で止まっても、残りは `pending` のまま保存済み。作業画面の「一括再引当」で復旧できる
  (`Process.monitor/1` で異常終了を検出して案内する)。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.SlipComponents

  alias FoodShip.ShippingSlips
  alias FoodShip.ShippingSlips.{Bulk, CsvParser}
  alias FoodShip.Utils.Permission
  alias FoodShipWeb.SlipMessages

  # エラー一覧に出す最大行数(超過分は件数だけ表示する)
  @max_errors_shown 200
  @interrupted_message "引当の処理が中断しました。作業画面の「一括再引当」で、残りを引き当ててください。"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        CSV 一括取込
        <:subtitle>
          UTF-8 の CSV(1 行目は見出し行)。列: {Enum.join(CsvParser.columns(), ", ")}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/shipping_slips"} class="btn" id="back-to-slips">作業画面へ</.link>
        </:actions>
      </.header>

      <div
        :if={!@warehouse_configured}
        id="warehouse-warning"
        role="alert"
        class="alert alert-warning"
      >
        対象倉庫が設定されていません。管理者に連絡してください。
      </div>

      <form id="import-form" phx-submit="import" phx-change="validate" class="space-y-2">
        <.live_file_input
          upload={@uploads.csv}
          class="file-input file-input-bordered w-full max-w-md"
          disabled={@phase == :importing}
        />
        <p :for={entry <- @uploads.csv.entries} class="text-sm">
          <span :for={error <- upload_errors(@uploads.csv, entry)} class="text-error">
            {upload_error_message(error)}
          </span>
        </p>
        <p :for={error <- upload_errors(@uploads.csv)} class="text-sm text-error">
          {upload_error_message(error)}
        </p>
        <button
          type="submit"
          class="btn btn-primary"
          id="import-submit"
          disabled={submit_disabled?(@phase, @warehouse_configured, @uploads.csv.entries)}
        >
          取り込む
        </button>
      </form>

      <div :if={@file_error} id="import-file-error" role="alert" class="alert alert-error">
        {@file_error}
      </div>

      <div :if={@errors != []} id="import-errors" role="alert" class="space-y-2">
        <p class="text-error font-semibold">
          検証エラーが {@error_count} 件あります。1 件も取り込んでいません。修正してもう一度取り込んでください。
        </p>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>行</th>
              <th>内容</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={error <- @errors} id={"import-error-#{error.line}-#{error.index}"}>
              <td class="whitespace-nowrap">{error.line} 行目</td>
              <td>{error.message}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@error_count > length(@errors)} class="text-sm">
          ほか {@error_count - length(@errors)} 件(先頭 {length(@errors)} 件を表示)
        </p>
      </div>

      <div :if={@phase != :idle} class="space-y-3" id="import-result">
        <.bulk_progress id="import-progress" label="引当" done={@done} total={@total} />
        <p :if={@phase == :done and @summary} id="import-summary" class="font-semibold">
          {@summary}
        </p>
        <.link
          :if={@phase == :done and @first_date}
          navigate={~p"/shipping_slips?#{%{date: Date.to_iso8601(@first_date)}}"}
          class="btn btn-sm"
          id="go-to-slips"
        >
          作業画面で確認する({@first_date})
        </.link>
        <.bulk_results id="import-results" rows={@streams.results} show_line />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:warehouse_configured, ShippingSlips.warehouse_configured?())
     |> assign(:errors, [])
     |> assign(:error_count, 0)
     |> assign(:file_error, nil)
     |> reset_run()
     |> stream(:results, [])
     |> allow_upload(:csv,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: CsvParser.max_bytes(),
       auto_upload: false
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("import", _params, socket) do
    cond do
      !Permission.can?(socket.assigns.current_scope.user, :manage_shipping_slips) ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      socket.assigns.phase == :importing ->
        {:noreply, socket}

      true ->
        case consume_uploaded_entries(socket, :csv, &read_entry/2) do
          [binary] ->
            {:noreply, import_csv(socket, binary)}

          [] ->
            {:noreply, put_flash(socket, :error, "CSV ファイルを選択してください。")}
        end
    end
  end

  @impl true
  def handle_info({:bulk_progress, ref, line, slip, result}, socket) do
    case socket.assigns.run do
      %{ref: ^ref} -> {:noreply, record_progress(socket, line, slip, result)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:bulk_done, ref}, socket) do
    case socket.assigns.run do
      %{ref: ^ref, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        {:noreply, finish(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # 引当の Task が最後まで進まずに終了した(完了通知より先に来た場合のみ異常終了)
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, socket) do
    case socket.assigns.run do
      %{monitor: ^monitor} ->
        {:noreply,
         socket
         |> assign(:phase, :done)
         |> assign(:run, nil)
         |> assign(:summary, nil)
         |> put_flash(:error, @interrupted_message)}

      _ ->
        {:noreply, socket}
    end
  end

  ## 取込

  defp import_csv(socket, binary) do
    scope = socket.assigns.current_scope

    case ShippingSlips.import_csv(scope, binary) do
      {:ok, saved} ->
        OperationLog.info(socket, "CSV から伝票を取り込みました。", :create, %{count: length(saved)})
        start_allocation(socket, saved)

      {:error, {:invalid, errors}} ->
        socket
        |> reset_run()
        |> stream(:results, [], reset: true)
        |> assign(:file_error, nil)
        |> assign_errors(errors)

      {:error, {:file, message}} ->
        socket
        |> reset_run()
        |> stream(:results, [], reset: true)
        |> assign(:file_error, message)
        |> assign_errors([])

      {:error, reason} ->
        put_flash(socket, :error, SlipMessages.error_message(reason))
    end
  end

  defp read_entry(%{path: path}, _entry), do: {:ok, File.read!(path)}

  defp assign_errors(socket, errors) do
    shown =
      errors
      |> Enum.take(@max_errors_shown)
      |> Enum.with_index()
      |> Enum.map(fn {error, index} -> Map.put(error, :index, index) end)

    socket
    |> assign(:errors, shown)
    |> assign(:error_count, length(errors))
  end

  # 保存済みの全行を「処理待ち」で表示し、Task で 1 件ずつ引当する
  defp start_allocation(socket, saved) do
    ref = make_ref()
    pid = self()
    scope = socket.assigns.current_scope
    lines = Map.new(saved, fn {line, slip} -> {slip.id, line} end)
    slips = Enum.map(saved, fn {_line, slip} -> slip end)

    rows = for {line, slip} <- saved, do: bulk_row(slip, line, :waiting)

    notify = fn _index, _total, slip, result ->
      send(pid, {:bulk_progress, ref, Map.fetch!(lines, slip.id), slip, result})
    end

    {:ok, task_pid} =
      Task.start(fn ->
        Bulk.run(scope, slips, &ShippingSlips.allocate_shipping_slip/2, notify)
        send(pid, {:bulk_done, ref})
      end)

    first_date = slips |> List.first() |> Map.fetch!(:scheduled_ship_date)

    socket
    |> assign(:errors, [])
    |> assign(:error_count, 0)
    |> assign(:file_error, nil)
    |> assign(:phase, :importing)
    |> assign(:total, length(slips))
    |> assign(:done, 0)
    |> assign(:counts, %{})
    |> assign(:summary, nil)
    |> assign(:first_date, first_date)
    |> assign(:run, %{ref: ref, monitor: Process.monitor(task_pid)})
    |> stream(:results, rows, reset: true)
  end

  defp record_progress(socket, line, slip, result) do
    {kind, _text} = SlipMessages.bulk_outcome(result)

    if kind != :error do
      {_kind, message} = SlipMessages.allocation_result(result)
      OperationLog.info(socket, message, :update, result_slip(result))
    end

    socket
    |> update(:done, &(&1 + 1))
    |> update(:counts, &Map.update(&1, kind, 1, fn count -> count + 1 end))
    |> stream_insert(:results, bulk_result_row(slip, line, result))
  end

  defp result_slip({:ok, slip, _info}), do: slip

  defp finish(socket) do
    counts = socket.assigns.counts
    summary = SlipMessages.bulk_summary(:allocate, counts)
    OperationLog.info(socket, "CSV 取込の引当を終えました。#{summary}", :update, counts)

    socket
    |> assign(:phase, :done)
    |> assign(:run, nil)
    |> assign(:summary, summary)
    |> put_flash(:info, summary)
  end

  defp reset_run(socket) do
    socket
    |> assign(:phase, :idle)
    |> assign(:total, 0)
    |> assign(:done, 0)
    |> assign(:counts, %{})
    |> assign(:summary, nil)
    |> assign(:first_date, nil)
    |> assign(:run, nil)
  end

  # 実行中・倉庫が未設定・ファイル未選択・選んだファイルに問題がある(拡張子・サイズ)ときは送信できない
  defp submit_disabled?(phase, warehouse_configured, entries) do
    phase == :importing or !warehouse_configured or entries == [] or
      Enum.any?(entries, &(!&1.valid?))
  end

  defp upload_error_message(:too_large), do: "ファイルが大きすぎます(上限 1 MB)。"
  defp upload_error_message(:not_accepted), do: "CSV ファイル(.csv)を選択してください。"
  defp upload_error_message(:too_many_files), do: "ファイルは 1 つだけ選択してください。"
  defp upload_error_message(_other), do: "ファイルを読み込めませんでした。"
end
