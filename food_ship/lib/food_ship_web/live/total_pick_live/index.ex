defmodule FoodShipWeb.TotalPickLive.Index do
  @moduledoc """
  トータルピックの一覧（全ロール参照）。出荷予定日・発注元・メーカー・状態で絞り込み、ページ送りする。
  作成は作業画面の出荷予定日タブから行う。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.SlipComponents

  alias FoodShip.{Clients, TotalPicks}
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.ConvertDatetime

  @statuses %{"issued" => :issued, "outdated" => :outdated, "cancelled" => :cancelled}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        トータルピック
        <:actions>
          <.link navigate={~p"/shipping_slips"} class="btn" id="to-work-screen">作業画面へ</.link>
        </:actions>
      </.header>

      <form id="pick-filter" phx-change="filter" class="flex flex-wrap items-end gap-3">
        <label class="form-control">
          <span class="label-text text-sm">出荷予定日</span>
          <input
            type="date"
            name="date"
            value={@params["date"]}
            class="input input-sm"
            aria-label="出荷予定日"
          />
        </label>
        <label class="form-control">
          <span class="label-text text-sm">発注元</span>
          <select name="client_id" class="select select-sm" aria-label="発注元">
            <option value="">すべて</option>
            <option
              :for={client <- @clients}
              value={client.id}
              selected={@params["client_id"] == client.id}
            >
              {client.client_name}
            </option>
          </select>
        </label>
        <label class="form-control">
          <span class="label-text text-sm">メーカー</span>
          <select name="maker_id" class="select select-sm" aria-label="メーカー">
            <option value="">すべて</option>
            <option
              :for={maker <- @makers}
              value={maker.inventory_maker_id}
              selected={@params["maker_id"] == maker.inventory_maker_id}
            >
              {maker.maker_name}
            </option>
          </select>
        </label>
        <label class="form-control">
          <span class="label-text text-sm">状態</span>
          <select name="status" class="select select-sm" aria-label="状態">
            <option value="">すべて</option>
            <option
              :for={status <- TotalPick.statuses()}
              value={status}
              selected={@params["status"] == to_string(status)}
            >
              {TotalPick.status_label(status)}
            </option>
          </select>
        </label>
      </form>

      <div class="overflow-x-auto">
        <table class="table" id="total-picks">
          <thead>
            <tr>
              <th>ピック番号</th>
              <th class="text-right">版</th>
              <th>出荷予定日</th>
              <th>発注元</th>
              <th>メーカー</th>
              <th class="text-right">伝票数</th>
              <th>状態</th>
              <th>発行日時</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={pick <- @page.entries} id={"pick-#{pick.id}"}>
              <td class="whitespace-nowrap">
                <.link navigate={~p"/total_picks/#{pick.id}"} class="link">
                  {TotalPick.pick_no_label(pick)}
                </.link>
              </td>
              <td class="text-right">{pick.revision}</td>
              <td>{pick.scheduled_ship_date}</td>
              <td>{pick.client.client_name}</td>
              <td>{pick.maker_name}</td>
              <td class="text-right">{pick.slip_count}</td>
              <td><.pick_status_badge status={pick.status} /></td>
              <td class="whitespace-nowrap">{ConvertDatetime.format_jst(pick.issued_at)}</td>
            </tr>
            <tr :if={@page.entries == []}>
              <td colspan="8" class="text-center text-sm" id="no-picks">
                該当するトータルピックはありません。
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} base_path={~p"/total_picks"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:clients, Clients.all_clients())
     |> assign(:makers, TotalPicks.list_makers())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = Map.take(params, ["date", "client_id", "maker_id", "status", "page"])

    page =
      params
      |> to_filters()
      |> TotalPicks.list_total_picks(parse_page(params["page"]))

    {:noreply, socket |> assign(:params, params) |> assign(:page, page)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(["date", "client_id", "maker_id", "status"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/total_picks?#{query}")}
  end

  defp to_filters(params) do
    %{
      scheduled_ship_date: parse_date(params["date"]),
      client_id: cast_id(params["client_id"]),
      inventory_maker_id: cast_id(params["maker_id"]),
      status: Map.get(@statuses, params["status"])
    }
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp cast_id(value) do
    case Ecto.Type.cast(Ecto.ULID, value) do
      {:ok, id} when not is_nil(id) -> id
      _ -> nil
    end
  end

  defp parse_page(value) do
    case Integer.parse(value || "") do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end
end
