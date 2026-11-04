defmodule FoodVaultWeb.InventoryReceiptLive.Form do
  @moduledoc """
  入荷登録(`staff` 以上)。

  ケース数・バラ数を入力すると、商品のケース入数から総バラ数(`総数:〇〇 個`)をリアルタイムに表示する。
  期限区分が「管理なし」の商品は期限日を入力せず、「期限なし」で登録する。
  """

  use FoodVaultWeb, :live_view

  alias FoodVault.{Inventories, Items, Warehouses}
  alias FoodVault.Utils.{Calc, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>入荷登録</.header>

        <.form for={@form} id="receipt-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:warehouse_id]}
            type="select"
            label="倉庫"
            prompt="選択してください"
            options={Enum.map(@warehouses, &{"#{&1.warehouse_code} #{&1.warehouse_name}", &1.id})}
            required
          />
          <.input
            field={@form[:item_id]}
            type="select"
            label="商品"
            prompt="選択してください"
            options={Enum.map(@items, &{"#{&1.item_code} #{&1.item_name}", &1.id})}
            required
          />
          <div :if={@item} class="text-sm text-base-content/70" id="item-info">
            ケース入数 {@item.units_per_case}
          </div>
          <div :if={@no_expiration?} class="fieldset mb-2" id="no-expiration">
            <span class="label mb-1">期限日</span>
            <span>期限なし</span>
          </div>
          <.input
            :if={!@no_expiration?}
            field={@form[:expiration_date]}
            type="date"
            label="期限日"
          />
          <.input field={@form[:received_date]} type="date" label="入荷日" required />
          <.input field={@form[:case_qty]} type="number" label="ケース数" min="0" />
          <.input field={@form[:piece_qty]} type="number" label="バラ数" min="0" />
          <p class="mb-4 font-semibold" id="total-pieces">総数:{@total} 個</p>
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">入荷を登録する</.button>
            <.link navigate={~p"/inventory_lots"} class="btn">キャンセル</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:warehouses, Warehouses.all_warehouses())
      |> assign(:items, Items.all_items())
      |> assign_changeset(Inventories.change_receipt())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"receipt" => params}, socket) do
    changeset = params |> Inventories.change_receipt() |> Map.put(:action, :validate)
    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", %{"receipt" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :receive_inventory) do
      save(socket, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, params) do
    case Inventories.receive_inventory(socket.assigns.current_scope.user, params) do
      {:ok, %{lot: lot}} ->
        OperationLog.info(socket, "入荷を登録しました。", :create, lot)

        {:noreply,
         socket
         |> put_flash(:info, "入荷を登録しました。")
         |> push_navigate(to: ~p"/inventory_lots/#{lot.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  # フォームと、選択中の商品に依存する表示(入数・期限なし・総バラ数)をまとめて更新する
  defp assign_changeset(socket, changeset) do
    item_id = Ecto.Changeset.get_field(changeset, :item_id)
    item = item_id && Enum.find(socket.assigns.items, &(&1.id == item_id))

    total =
      Calc.total_pieces(
        Ecto.Changeset.get_field(changeset, :case_qty),
        Ecto.Changeset.get_field(changeset, :piece_qty),
        item && item.units_per_case
      )

    socket
    |> assign(:form, to_form(changeset, as: "receipt"))
    |> assign(:item, item)
    |> assign(:no_expiration?, match?(%{expiration_type: :none}, item))
    |> assign(:total, if(item, do: total, else: 0))
  end
end
