defmodule FoodVaultWeb.InventoryTransactionLive.Index do
  @moduledoc "受払履歴(全ロール参照)。ロット・商品・期間・処理区分・操作者で検索する。追記専用のため操作は無い。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.{Accounts, Inventories, Items, Warehouses}
  alias FoodVault.Inventories.InventoryTransaction
  alias FoodVault.Utils.{Calc, ConvertDatetime}

  @filter_keys ~w(warehouse_id item_id user_id transaction_type from to lot_id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>受払履歴</.header>

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
        <.input
          field={@filter_form[:transaction_type]}
          type="select"
          label="処理区分"
          prompt="すべて"
          options={
            for t <- InventoryTransaction.transaction_types(),
                do: {InventoryTransaction.transaction_type_label(t), t}
          }
        />
        <.input
          field={@filter_form[:user_id]}
          type="select"
          label="操作ユーザー"
          prompt="すべて"
          options={Enum.map(@users, &{&1.name, &1.id})}
        />
        <.input field={@filter_form[:from]} type="date" label="期間(から)" />
        <.input field={@filter_form[:to]} type="date" label="期間(まで)" />
        <.input field={@filter_form[:lot_id]} type="hidden" />
      </.form>

      <div class="overflow-x-auto">
        <table class="table table-sm" id="transactions">
          <thead>
            <tr>
              <th>日時</th>
              <th>区分</th>
              <th>倉庫</th>
              <th>商品</th>
              <th>期限日</th>
              <th class="text-right">ケース</th>
              <th class="text-right">バラ</th>
              <th>備考</th>
              <th>操作者</th>
              <th>移動ペア</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={tx <- @page.entries} id={"transaction-#{tx.id}"}>
              <td>{ConvertDatetime.format_jst(tx.inserted_at)}</td>
              <td>{InventoryTransaction.transaction_type_label(tx.transaction_type)}</td>
              <td>{tx.lot.warehouse.warehouse_name}</td>
              <td>
                <.link navigate={~p"/inventory_lots/#{tx.lot_id}"} class="link">
                  {tx.lot.item.item_code} {tx.lot.item.item_name}
                </.link>
              </td>
              <td>{Calc.expiration_label(tx.lot.expiration_date)}</td>
              <td class="text-right">{tx.case_diff}</td>
              <td class="text-right">{tx.piece_diff}</td>
              <td>{tx.note}</td>
              <td>{(tx.user && tx.user.name) || tx.operator}</td>
              <td>{tx.transfer_id}</td>
            </tr>
            <tr :if={@page.entries == []}>
              <td colspan="10" class="text-center text-base-content/60">履歴がありません。</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} base_path={~p"/inventory_transactions"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:warehouses, Warehouses.all_warehouses())
     |> assign(:items, Items.all_items())
     |> assign(:users, Accounts.list_users())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(:page, Inventories.list_inventory_transactions(params))
     |> assign(:filter_form, to_form(params, as: :filter))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query =
      filter
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/inventory_transactions?#{query}")}
  end
end
