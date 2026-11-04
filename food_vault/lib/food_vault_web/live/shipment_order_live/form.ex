defmodule FoodVaultWeb.ShipmentOrderLive.Form do
  @moduledoc """
  出庫オーダーの登録(`staff` 以上)。登録と同時に自動引当する。

  画面登録のオーダーは `external_slip_id` を持たない(フォームの値に含まれていても使わない)。
  明細は可変個で `cast_assoc` を使わないため、フォームの値をそのまま保持し、
  `Context` が返すエラーの一覧(`path` / `message`)を各入力欄に対応づけて表示する。
  在庫不足のときは、不足した全明細分の不足数を表で示す。
  """

  use FoodVaultWeb, :live_view

  alias FoodVault.{Items, ShipmentOrders, Warehouses}
  alias FoodVault.Utils.{Calc, ConvertDatetime, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>出庫オーダーを登録する</.header>

      <.form for={@form} id="order-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <div class="flex flex-wrap gap-3">
          <.input
            name="order[warehouse_id]"
            id="order_warehouse_id"
            type="select"
            label="出庫倉庫"
            prompt="選択してください"
            value={@params["warehouse_id"]}
            options={Enum.map(@warehouses, &{&1.warehouse_name, &1.id})}
            errors={errors_for(@errors, ["warehouse_id"])}
          />
          <.input
            name="order[shipment_date]"
            id="order_shipment_date"
            type="date"
            label="出庫予定日"
            value={@params["shipment_date"]}
            errors={errors_for(@errors, ["shipment_date"])}
          />
        </div>

        <p :for={message <- errors_for(@errors, ["lines"])} class="text-error">{message}</p>

        <div class="overflow-x-auto">
          <table class="table table-sm" id="lines">
            <thead>
              <tr>
                <th>商品</th>
                <th>ケース数</th>
                <th>バラ数</th>
                <th>総数</th>
                <th>最低許容期限日</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{key, row} <- @rows} id={"line-#{key}"}>
                <td>
                  <.input
                    name={"order[lines][#{key}][item_id]"}
                    id={"order_lines_#{key}_item_id"}
                    type="select"
                    prompt="選択してください"
                    value={row["item_id"]}
                    options={Enum.map(@items, &{"#{&1.item_code} #{&1.item_name}", &1.id})}
                    errors={errors_for(@errors, ["lines", index_of(@rows, key), "item_id"])}
                  />
                </td>
                <td>
                  <.input
                    name={"order[lines][#{key}][req_cases]"}
                    id={"order_lines_#{key}_req_cases"}
                    type="number"
                    min="0"
                    value={row["req_cases"]}
                    errors={errors_for(@errors, ["lines", index_of(@rows, key), "req_cases"])}
                  />
                </td>
                <td>
                  <.input
                    name={"order[lines][#{key}][req_pieces]"}
                    id={"order_lines_#{key}_req_pieces"}
                    type="number"
                    min="0"
                    value={row["req_pieces"]}
                    errors={errors_for(@errors, ["lines", index_of(@rows, key), "req_pieces"])}
                  />
                </td>
                <td id={"line-total-#{key}"}>{line_total(row, @items)} 個</td>
                <td>
                  <.input
                    name={"order[lines][#{key}][min_expiration_date]"}
                    id={"order_lines_#{key}_min_expiration_date"}
                    type="date"
                    value={row["min_expiration_date"]}
                    errors={
                      errors_for(@errors, ["lines", index_of(@rows, key), "min_expiration_date"])
                    }
                  />
                </td>
                <td>
                  <button
                    :if={length(@rows) > 1}
                    type="button"
                    phx-click="remove_line"
                    phx-value-key={key}
                    class="btn btn-sm btn-ghost"
                    id={"remove-line-#{key}"}
                  >
                    削除
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <button type="button" phx-click="add_line" class="btn btn-sm" id="add-line">
          明細を追加する
        </button>

        <div :if={@shortages != []} role="alert" class="alert alert-error block" id="shortages">
          <p class="font-semibold">在庫が不足しています。オーダーは登録されていません。</p>
          <ul>
            <li :for={s <- @shortages}>
              {item_label(@items, s.item_id)}:
              不足 {s.shortage_cases} ケース / {s.shortage_pieces} バラ
            </li>
          </ul>
        </div>

        <div class="flex gap-2">
          <.button class="btn btn-primary" phx-disable-with="登録中...">登録して引き当てる</.button>
          <.link navigate={~p"/shipment_orders"} class="btn">キャンセル</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    params = %{
      "warehouse_id" => "",
      "shipment_date" => Date.to_iso8601(ConvertDatetime.today_jst())
    }

    {:ok,
     socket
     |> assign(:warehouses, Warehouses.all_warehouses())
     |> assign(:items, Items.all_items())
     |> assign(:params, params)
     |> assign(:rows, [{"0", blank_row()}])
     |> assign(:errors, [])
     |> assign(:shortages, [])
     |> assign(:form, to_form(%{}, as: :order))}
  end

  @impl true
  def handle_event("validate", %{"order" => order_params}, socket) do
    {:noreply, put_params(socket, order_params)}
  end

  def handle_event("add_line", _params, socket) do
    next =
      socket.assigns.rows
      |> Enum.map(fn {key, _} -> String.to_integer(key) end)
      |> Enum.max()
      |> Kernel.+(1)

    {:noreply,
     assign(socket, :rows, socket.assigns.rows ++ [{Integer.to_string(next), blank_row()}])}
  end

  def handle_event("remove_line", %{"key" => key}, socket) do
    {:noreply, assign(socket, :rows, List.keydelete(socket.assigns.rows, key, 0))}
  end

  def handle_event("save", %{"order" => order_params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_shipment_order) do
      socket |> put_params(order_params) |> save()
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket) do
    attrs = %{
      "warehouse_id" => socket.assigns.params["warehouse_id"],
      "shipment_date" => socket.assigns.params["shipment_date"],
      "lines" => Map.new(socket.assigns.rows)
    }

    case ShipmentOrders.allocate_shipment_order(socket.assigns.current_scope.user, attrs) do
      {:ok, %{shipment_order: order}} ->
        OperationLog.info(socket, "出庫オーダーを登録しました。", :create, order)

        {:noreply,
         socket
         |> put_flash(:info, "出庫オーダーを登録しました。")
         |> push_navigate(to: ~p"/shipment_orders/#{order.id}")}

      {:error, :validation_failed, errors} ->
        {:noreply, assign(socket, errors: errors, shortages: [])}

      {:error, :insufficient_stock, shortages} ->
        {:noreply, assign(socket, errors: [], shortages: shortages)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  # フォームの値を保持する。送信元は order[...] のみ(external_slip_id などは取り込まない)
  defp put_params(socket, order_params) do
    rows =
      order_params
      |> Map.get("lines", %{})
      |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
      |> Enum.map(fn {key, row} -> {key, Map.merge(blank_row(), row)} end)

    socket
    |> assign(:params, Map.take(order_params, ["warehouse_id", "shipment_date"]))
    |> assign(:rows, if(rows == [], do: socket.assigns.rows, else: rows))
    |> assign(:errors, [])
    |> assign(:shortages, [])
  end

  defp blank_row,
    do: %{"item_id" => "", "req_cases" => "", "req_pieces" => "", "min_expiration_date" => ""}

  defp index_of(rows, key), do: Enum.find_index(rows, fn {k, _} -> k == key end)

  defp errors_for(errors, path) do
    for %{path: ^path, message: message} <- errors, do: message
  end

  defp line_total(row, items) do
    case Enum.find(items, &(&1.id == row["item_id"])) do
      nil -> 0
      item -> Calc.total_pieces(row["req_cases"], row["req_pieces"], item.units_per_case)
    end
  end

  defp item_label(items, item_id) do
    case Enum.find(items, &(&1.id == item_id)) do
      nil -> item_id
      item -> "#{item.item_code} #{item.item_name}"
    end
  end
end
