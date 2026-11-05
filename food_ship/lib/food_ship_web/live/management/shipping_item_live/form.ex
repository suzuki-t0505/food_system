defmodule FoodShipWeb.Management.ShippingItemLive.Form do
  @moduledoc """
  発送商品の登録(`:new`)と編集(`:edit`)。`admin` のみ。

  登録は、商品コードで在庫側の値(商品 ID・商品名・メーカー ID・メーカー名)を取得してから、
  標準箱数・商品数量を入力して保存する。在庫 API は `Task` ＋ `handle_info` で呼ぶ。
  在庫側の値は画面のフォームには載せず、取得結果をサーバー側(`fetched`)で保持する。
  編集は換算(標準箱数・商品数量)だけ。在庫側の値は一覧の「再取得」で更新する。
  """

  use FoodShipWeb, :live_view

  alias FoodShip.ShippingItems
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.Utils.Permission
  alias FoodShipWeb.InventoryMessages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4">
        <.header>{@page_title}</.header>

        <.form
          :if={@live_action == :new}
          for={%{}}
          as={:fetch}
          id="fetch-form"
          phx-submit="fetch"
          class="flex items-end gap-2"
        >
          <div class="flex-1">
            <.input
              name="item_code"
              id="fetch-item-code"
              type="text"
              label="商品コード(在庫システム)"
              value={@item_code}
              required
            />
          </div>
          <.button class="btn" disabled={@fetching} phx-disable-with="取得中...">取得</.button>
        </.form>

        <dl :if={@fetched} id="inventory-item" class="space-y-1 text-sm">
          <div class="flex gap-2">
            <dt class="font-semibold">商品コード</dt><dd>{@fetched.item_code}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="font-semibold">商品名</dt><dd>{@fetched.item_name}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="font-semibold">メーカー</dt>
            <dd>{@fetched.maker_name}</dd>
          </div>
        </dl>

        <.form
          :if={@fetched}
          for={@form}
          id="shipping-item-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.input
            field={@form[:boxes_per_order]}
            type="number"
            min="1"
            label="標準箱数(1 件あたり)"
            required
          />
          <.input
            field={@form[:pieces_per_order]}
            type="number"
            min="1"
            label="商品数量(1 件あたりのバラ数)"
            required
          />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/shipping_items"} class="btn">キャンセル</.link>
          </div>
        </.form>

        <.link :if={!@fetched} navigate={~p"/masters/shipping_items"} class="btn">キャンセル</.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "発送商品を登録する")
    |> assign(:shipping_item, %ShippingItem{})
    |> assign(:item_code, "")
    |> assign(:fetched, nil)
    |> assign(:fetching, false)
    |> assign_form(ShippingItems.change_shipping_item(%ShippingItem{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = ShippingItems.get_shipping_item!(id)

    socket
    |> assign(:page_title, "発送商品を編集する")
    |> assign(:shipping_item, item)
    |> assign(:item_code, item.item_code)
    |> assign(:fetched, Map.take(item, [:item_code, :item_name, :maker_name]))
    |> assign(:fetching, false)
    |> assign_form(ShippingItems.change_shipping_item(item))
  end

  @impl true
  def handle_event("fetch", %{"item_code" => item_code}, socket) do
    cond do
      !allowed?(socket) ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}

      socket.assigns.fetching ->
        {:noreply, socket}

      true ->
        pid = self()
        Task.start(fn -> send(pid, {:fetched, ShippingItems.fetch_inventory_item(item_code)}) end)
        {:noreply, socket |> assign(:fetching, true) |> assign(:item_code, item_code)}
    end
  end

  def handle_event("validate", %{"shipping_item" => params}, socket) do
    changeset = changeset(socket, params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"shipping_item" => params}, socket) do
    if allowed?(socket) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  @impl true
  def handle_info({:fetched, result}, socket) do
    socket = assign(socket, :fetching, false)

    case result do
      {:ok, attrs} ->
        {:noreply,
         socket
         |> assign(:fetched, attrs)
         |> assign(:item_code, attrs.item_code)
         |> assign_form(ShippingItems.change_shipping_item(%ShippingItem{}, attrs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:fetched, nil)
         |> put_flash(:error, "在庫システムに、その商品コードの有効な商品が見つかりません。")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, InventoryMessages.error_message(reason))}
    end
  end

  # 登録は、取得済みの在庫側の値(サーバー側で保持)にフォームの換算を合わせて検証する
  defp changeset(%{assigns: %{live_action: :new, fetched: fetched}} = socket, params) do
    ShippingItems.change_shipping_item(
      socket.assigns.shipping_item,
      Map.merge(params, stringify(fetched))
    )
  end

  defp changeset(socket, params),
    do: ShippingItems.change_shipping_item(socket.assigns.shipping_item, params)

  defp save(%{assigns: %{fetched: nil}} = socket, :new, _params),
    do: {:noreply, put_flash(socket, :error, "先に商品コードで在庫システムから取得してください。")}

  defp save(socket, :new, params) do
    attrs = Map.merge(params, stringify(socket.assigns.fetched))

    socket.assigns.current_scope
    |> ShippingItems.create_shipping_item(attrs)
    |> handle_result(socket, "発送商品を登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> ShippingItems.update_shipping_item(socket.assigns.shipping_item, params)
    |> handle_result(socket, "発送商品を更新しました。", :update)
  end

  defp handle_result({:ok, item}, socket, message, category) do
    OperationLog.info(socket, message, category, item)

    {:noreply,
     socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/shipping_items")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category) do
    socket = assign_form(socket, changeset)

    # 在庫側の値の重複(登録済みの商品など)は、フォームに項目が無いので画面上部に出す
    case Keyword.take(changeset.errors, [:item_code, :inventory_item_id]) do
      [] -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "この商品はすでに発送商品として登録されています。")}
    end
  end

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp allowed?(socket), do: Permission.can?(socket.assigns.current_scope.user, :manage_masters)

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: "shipping_item"))
end
