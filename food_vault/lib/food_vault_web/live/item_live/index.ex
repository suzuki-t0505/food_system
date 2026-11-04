defmodule FoodVaultWeb.ItemLive.Index do
  @moduledoc "商品一覧(全ロール参照)。アーカイブ・復帰は `admin` のみ。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.Items
  alias FoodVault.Items.Item
  alias FoodVault.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        商品
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/items/new"}
            class="btn btn-primary"
            id="new-item"
          >
            商品を登録する
          </.link>
        </:actions>
      </.header>

      <label class="label gap-2">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          id="include-archived"
          checked={@params["include_archived"] == "true"}
          phx-click="toggle_archived"
        /> アーカイブ済みも表示
      </label>

      <div class="overflow-x-auto">
        <table class="table" id="items">
          <thead>
            <tr>
              <th>コード</th>
              <th>名称</th>
              <th>メーカー</th>
              <th class="text-right">ケース入数</th>
              <th>期限区分</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @page.entries} id={"item-#{item.id}"}>
              <td>{item.item_code}</td>
              <td>{item.item_name}</td>
              <td>{item.maker.maker_name}</td>
              <td class="text-right">{item.units_per_case}</td>
              <td>{Item.expiration_type_label(item.expiration_type)}</td>
              <td><.archived_badge archived_at={item.archived_at} /></td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/items/#{item.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-item-#{item.id}"}
                >
                  編集
                </.link>
                <button
                  :if={!Item.archived?(item)}
                  phx-click="archive"
                  phx-value-id={item.id}
                  data-confirm="この商品をアーカイブします。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-item-#{item.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={Item.archived?(item)}
                  phx-click="restore"
                  phx-value-id={item.id}
                  class="btn btn-sm"
                  id={"restore-item-#{item.id}"}
                >
                  復帰
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.pagination page={@page} base_path={~p"/masters/items"} params={@params} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, params) |> assign_page()}
  end

  @impl true
  def handle_event("toggle_archived", _params, socket) do
    params =
      case socket.assigns.params do
        %{"include_archived" => "true"} = p -> Map.delete(p, "include_archived")
        p -> Map.put(p, "include_archived", "true")
      end

    {:noreply, push_patch(socket, to: ~p"/masters/items?#{Map.delete(params, "page")}")}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    change(socket, id, &Items.archive_item/2, "商品をアーカイブしました。")
  end

  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, &Items.restore_item/2, "商品を復帰しました。")
  end

  defp change(socket, id, fun, message) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      case fun.(socket.assigns.current_scope, Items.get_item!(id)) do
        {:ok, item} ->
          OperationLog.info(socket, message, :update, item)
          {:noreply, socket |> put_flash(:info, message) |> assign_page()}

        {:error, :has_stock} ->
          {:noreply, put_flash(socket, :error, "在庫があるため、アーカイブできません。")}

        {:error, :archived_maker} ->
          {:noreply, put_flash(socket, :error, "メーカーがアーカイブ済みのため、復帰できません。")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "変更できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp assign_page(socket), do: assign(socket, :page, Items.list_items(socket.assigns.params))
end
