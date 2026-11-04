defmodule FoodVaultWeb.InventoryLotLive.Index do
  @moduledoc """
  在庫一覧(全ロール参照)。ロット別と商品別(倉庫 × 商品の合算)を切り替えて、
  `ケース数 | バラ数 | 総バラ数`・引当済・有効在庫を期限の近い順に表示する。
  """

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.{Inventories, Items, Warehouses}
  alias FoodVault.Utils.{Calc, Permission}

  @filter_keys ~w(warehouse_id item_id expiration_from expiration_to include_empty view)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        在庫一覧
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :receive_inventory)}
            navigate={~p"/inventory_receipts/new"}
            class="btn btn-primary"
            id="new-receipt"
          >
            入荷登録
          </.link>
        </:actions>
      </.header>

      <.form
        for={@filter_form}
        id="filter-form"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          field={@filter_form[:warehouse_id]}
          type="select"
          label="倉庫"
          prompt="すべて"
          options={Enum.map(@warehouses, &{&1.warehouse_name, &1.id})}
        />
        <.input
          field={@filter_form[:item_id]}
          type="select"
          label="商品"
          prompt="すべて"
          options={Enum.map(@items, &{"#{&1.item_code} #{&1.item_name}", &1.id})}
        />
        <.input field={@filter_form[:expiration_from]} type="date" label="期限日(から)" />
        <.input field={@filter_form[:expiration_to]} type="date" label="期限日(まで)" />
        <.input
          field={@filter_form[:view]}
          type="select"
          label="表示"
          options={[{"ロット別", "lots"}, {"商品別", "summary"}]}
        />
        <.input
          field={@filter_form[:include_empty]}
          type="checkbox"
          label="在庫 0 を含む"
          checked={@params["include_empty"] == "true"}
          value="true"
        />
      </.form>

      <div :if={@view == "lots"} class="overflow-x-auto">
        <table class="table table-sm" id="lots">
          <thead>
            <tr>
              <th>倉庫</th>
              <th>商品</th>
              <th>期限日</th>
              <th>入荷日</th>
              <th>在庫(ケース | バラ | 総バラ)</th>
              <th>引当済</th>
              <th>有効在庫</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={lot <- @page.entries} id={"lot-#{lot.id}"}>
              <td>{lot.warehouse.warehouse_name}</td>
              <td>
                <.link navigate={~p"/inventory_lots/#{lot.id}"} class="link">
                  {lot.item.item_code} {lot.item.item_name}
                </.link>
              </td>
              <td>{Calc.expiration_label(lot.expiration_date)}</td>
              <td>{lot.received_date}</td>
              <td>{quantity_text(lot.case_qty, lot.piece_qty, lot.item.units_per_case)}</td>
              <td>
                {quantity_text(
                  lot.allocated_case_qty,
                  lot.allocated_piece_qty,
                  lot.item.units_per_case
                )}
              </td>
              <td>
                <% eff = Calc.effective(lot) %>
                {quantity_text(eff.cases, eff.pieces, lot.item.units_per_case)}
              </td>
            </tr>
            <tr :if={@page.entries == []}>
              <td colspan="7" class="text-center text-base-content/60">在庫がありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@view == "summary"} class="overflow-x-auto">
        <table class="table table-sm" id="summaries">
          <thead>
            <tr>
              <th>倉庫</th>
              <th>商品</th>
              <th>最も近い期限</th>
              <th>在庫(ケース | バラ | 総バラ)</th>
              <th>引当済</th>
              <th>有効在庫</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @page.entries} id={"summary-#{s.warehouse_id}-#{s.item_id}"}>
              <td>{s.warehouse_name}</td>
              <td>{s.item_code} {s.item_name}</td>
              <td>{Calc.expiration_label(s.earliest_expiration)}</td>
              <td>{quantity_text(s.case_qty, s.piece_qty, s.units_per_case)}</td>
              <td>{quantity_text(s.allocated_case_qty, s.allocated_piece_qty, s.units_per_case)}</td>
              <td>
                {quantity_text(
                  s.case_qty - s.allocated_case_qty,
                  s.piece_qty - s.allocated_piece_qty,
                  s.units_per_case
                )}
              </td>
            </tr>
            <tr :if={@page.entries == []}>
              <td colspan="6" class="text-center text-base-content/60">在庫がありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} base_path={~p"/inventory_lots"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:warehouses, Warehouses.all_warehouses())
     |> assign(:items, Items.all_items())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "summary", do: "summary", else: "lots"

    page =
      if view == "summary",
        do: Inventories.list_inventory_summaries(params),
        else: Inventories.list_inventory_lots(params)

    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(:view, view)
     |> assign(:page, page)
     |> assign(:filter_form, to_form(Map.put_new(params, "view", view), as: :filter))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query =
      filter
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value in ["", "false"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/inventory_lots?#{query}")}
  end
end
