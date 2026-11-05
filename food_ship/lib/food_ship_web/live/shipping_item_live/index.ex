defmodule FoodShipWeb.ShippingItemLive.Index do
  @moduledoc """
  発送商品の一覧(全ロール参照)。登録・編集・アーカイブ・復帰・在庫側の値の再取得は `admin` のみ。

  再取得は在庫 API を呼ぶため `Task` ＋ `handle_info` で行い、実行中の行のボタンを無効化する。
  """

  use FoodShipWeb, :live_view

  import FoodShipWeb.MasterComponents

  alias FoodShip.ShippingItems
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.Utils.Permission
  alias FoodShipWeb.InventoryMessages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        発送商品
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/shipping_items/new"}
            class="btn btn-primary"
            id="new-shipping-item"
          >
            発送商品を登録する
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
        <table class="table" id="shipping-items">
          <thead>
            <tr>
              <th>商品コード</th>
              <th>商品名</th>
              <th>メーカー</th>
              <th class="text-right">標準箱数</th>
              <th class="text-right">商品数量(バラ)</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @shipping_items} id={"shipping-item-#{item.id}"}>
              <td>{item.item_code}</td>
              <td>{item.item_name}</td>
              <td>{item.maker_name}</td>
              <td class="text-right">{item.boxes_per_order}</td>
              <td class="text-right">{item.pieces_per_order}</td>
              <td><.archived_badge archived_at={item.archived_at} /></td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/shipping_items/#{item.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-shipping-item-#{item.id}"}
                >
                  編集
                </.link>
                <button
                  :if={!ShippingItem.archived?(item)}
                  phx-click="refetch"
                  phx-value-id={item.id}
                  disabled={MapSet.member?(@busy, item.id)}
                  class="btn btn-sm"
                  id={"refetch-shipping-item-#{item.id}"}
                >
                  在庫側から再取得
                </button>
                <button
                  :if={!ShippingItem.archived?(item)}
                  phx-click="archive"
                  phx-value-id={item.id}
                  data-confirm="この発送商品をアーカイブします。新規伝票の選択肢に出なくなります。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-shipping-item-#{item.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={ShippingItem.archived?(item)}
                  phx-click="restore"
                  phx-value-id={item.id}
                  class="btn btn-sm"
                  id={"restore-shipping-item-#{item.id}"}
                >
                  復帰
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :busy, MapSet.new())}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, params) |> assign_items()}
  end

  @impl true
  def handle_event("toggle_archived", _params, socket) do
    params =
      case socket.assigns.params do
        %{"include_archived" => "true"} = p -> Map.delete(p, "include_archived")
        p -> Map.put(p, "include_archived", "true")
      end

    {:noreply, push_patch(socket, to: ~p"/masters/shipping_items?#{params}")}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    change(socket, id, &ShippingItems.archive_shipping_item/2, "発送商品をアーカイブしました。")
  end

  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, &ShippingItems.restore_shipping_item/2, "発送商品を復帰しました。")
  end

  def handle_event("refetch", %{"id" => id}, socket) do
    cond do
      !allowed?(socket) ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}

      MapSet.member?(socket.assigns.busy, id) ->
        {:noreply, socket}

      true ->
        {:noreply, start_refetch(socket, ShippingItems.get_shipping_item!(id))}
    end
  end

  @impl true
  def handle_info({:refetch_result, id, result}, socket) do
    socket = update(socket, :busy, &MapSet.delete(&1, id))

    case result do
      {:ok, item} ->
        message = "在庫側の値を再取得しました。"
        OperationLog.info(socket, message, :update, item)
        {:noreply, socket |> put_flash(:info, message) |> assign_items()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "再取得した値を保存できませんでした。")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, InventoryMessages.error_message(reason))}
    end
  end

  defp start_refetch(socket, item) do
    pid = self()
    scope = socket.assigns.current_scope

    Task.start(fn ->
      send(pid, {:refetch_result, item.id, ShippingItems.refresh_from_inventory(scope, item)})
    end)

    update(socket, :busy, &MapSet.put(&1, item.id))
  end

  defp change(socket, id, fun, message) do
    if allowed?(socket) do
      case fun.(socket.assigns.current_scope, ShippingItems.get_shipping_item!(id)) do
        {:ok, item} ->
          OperationLog.info(socket, message, :update, item)
          {:noreply, socket |> put_flash(:info, message) |> assign_items()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "変更できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp allowed?(socket), do: Permission.can?(socket.assigns.current_scope.user, :manage_masters)

  defp assign_items(socket),
    do: assign(socket, :shipping_items, ShippingItems.list_shipping_items(socket.assigns.params))
end
