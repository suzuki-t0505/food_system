defmodule FoodVaultWeb.Management.InventoryAdjustmentLive.Form do
  @moduledoc """
  棚卸調整(`admin` のみ)。ロットを指定してケース数・バラ数を増減する。理由は必須。

  入荷訂正(数量の誤り)と荷まとめ(バラ → ケース)もこの画面で行う。荷まとめは、まとめるケース数を
  入力して換算ボタンを押すと、`ケース +k`・`バラ −k × 入数` が入力欄に入る。
  期限日・入荷日の誤りは、誤ったロットの全数を減算し、入荷登録で正しい期限日・入荷日で再入荷して直す。
  """

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.Inventories
  alias FoodVault.Utils.{Calc, Permission}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4">
        <.header>
          棚卸調整
          <:subtitle>
            {@lot.item.item_code} {@lot.item.item_name}({@lot.warehouse.warehouse_name}) 期限日 {Calc.expiration_label(
              @lot.expiration_date
            )} / 入荷日 {@lot.received_date}
          </:subtitle>
        </.header>

        <.list>
          <:item title="現在庫(ケース | バラ | 総バラ)">
            {quantity_text(@lot.case_qty, @lot.piece_qty, @lot.item.units_per_case)}
          </:item>
          <:item title="引当済">
            {quantity_text(
              @lot.allocated_case_qty,
              @lot.allocated_piece_qty,
              @lot.item.units_per_case
            )}
          </:item>
          <:item title="ケース入数">{@lot.item.units_per_case}</:item>
        </.list>

        <.form for={@form} id="adjustment-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:case_diff]}
            type="number"
            label="ケース数の増減(減算は負数)"
          />
          <.input
            field={@form[:piece_diff]}
            type="number"
            label="バラ数の増減(減算は負数)"
          />
          <.input field={@form[:note]} type="text" label="理由(必須)" />
          <p class="mb-4" id="preview">
            調整後: {quantity_text(@after_cases, @after_pieces, @lot.item.units_per_case)} (有効在庫 {quantity_text(
              @after_cases - @lot.allocated_case_qty,
              @after_pieces - @lot.allocated_piece_qty,
              @lot.item.units_per_case
            )})
          </p>
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">調整を登録する</.button>
            <.link navigate={~p"/inventory_lots/#{@lot.id}"} class="btn">キャンセル</.link>
          </div>
        </.form>

        <form id="bundle-form" phx-submit="apply_bundle" class="flex items-end gap-2">
          <div class="fieldset">
            <label for="bundle-cases" class="label mb-1">荷まとめ(バラ → ケース)するケース数</label>
            <input id="bundle-cases" name="k" type="number" min="1" class="input w-32" />
          </div>
          <button type="submit" class="btn btn-sm" id="apply-bundle">換算して入力欄に反映</button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    lot = Inventories.get_inventory_lot!(id)

    {:ok,
     socket
     |> assign(:lot, lot)
     |> assign_changeset(Inventories.change_adjustment())}
  end

  @impl true
  def handle_event("validate", %{"adjustment" => params}, socket) do
    changeset = params |> Inventories.change_adjustment() |> Map.put(:action, :validate)
    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("apply_bundle", %{"k" => k}, socket) do
    k = Calc.parse_int(k)
    upc = socket.assigns.lot.item.units_per_case

    params = %{
      "case_diff" => to_string(k),
      "piece_diff" => to_string(-k * upc),
      "note" => Ecto.Changeset.get_field(socket.assigns.changeset, :note) || "荷まとめ"
    }

    {:noreply, assign_changeset(socket, Inventories.change_adjustment(params))}
  end

  def handle_event("save", %{"adjustment" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :adjust_inventory) do
      save(socket, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, params) do
    case Inventories.adjust_inventory(
           socket.assigns.current_scope.user,
           socket.assigns.lot,
           params
         ) do
      {:ok, %{lot: lot}} ->
        OperationLog.info(socket, "棚卸調整を登録しました。", :update, lot)

        {:noreply,
         socket
         |> put_flash(:info, "棚卸調整を登録しました。")
         |> push_navigate(to: ~p"/inventory_lots/#{lot.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  # フォームと、入力に応じた調整後の数量のプレビューを更新する
  defp assign_changeset(socket, changeset) do
    lot = socket.assigns.lot

    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: "adjustment"))
    |> assign(:after_cases, lot.case_qty + diff(changeset, :case_diff))
    |> assign(:after_pieces, lot.piece_qty + diff(changeset, :piece_diff))
  end

  defp diff(changeset, field) do
    case Ecto.Changeset.get_field(changeset, field) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end
end
