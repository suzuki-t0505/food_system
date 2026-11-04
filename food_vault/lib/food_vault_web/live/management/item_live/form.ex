defmodule FoodVaultWeb.Management.ItemLive.Form do
  @moduledoc """
  商品の登録(`:new`)と編集(`:edit`)。`admin` のみ。

  ロット(在庫 0 を含む)がある商品は、ケース入数と期限区分を変更できない。
  編集画面では入力欄を無効にし、サーバー側(`Items.update_item/3`)でも拒否する。
  """

  use FoodVaultWeb, :live_view

  alias FoodVault.{Inventories, Items, Makers}
  alias FoodVault.Items.Item
  alias FoodVault.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>
          {@page_title}
          <:subtitle :if={@locked?}>
            ロットがあるため、ケース入数と期限区分は変更できません。
          </:subtitle>
        </.header>

        <.form for={@form} id="item-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:item_code]} type="text" label="商品コード" required />
          <.input field={@form[:item_name]} type="text" label="商品名" required />
          <.input
            field={@form[:maker_id]}
            type="select"
            label="メーカー"
            prompt="選択してください"
            options={Enum.map(@makers, &{&1.maker_name, &1.id})}
            required
          />
          <.input
            field={@form[:units_per_case]}
            type="number"
            label="ケース入数"
            min="1"
            disabled={@locked?}
            required
          />
          <.input
            field={@form[:expiration_type]}
            type="select"
            label="期限区分"
            prompt="選択してください"
            options={for t <- Item.expiration_types(), do: {Item.expiration_type_label(t), t}}
            disabled={@locked?}
            required
          />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/items"} class="btn">キャンセル</.link>
          </div>
        </.form>
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
    |> assign(:page_title, "商品を登録する")
    |> assign(:item, %Item{})
    |> assign(:locked?, false)
    |> assign_makers(nil)
    |> assign_form(Items.change_item(%Item{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = Items.get_item!(id)

    socket
    |> assign(:page_title, "商品を編集する")
    |> assign(:item, item)
    |> assign(:locked?, Inventories.item_has_lots?(item.id))
    |> assign_makers(item.maker_id)
    |> assign_form(Items.change_item(item))
  end

  # 選択肢は有効なメーカー。編集中の商品がアーカイブ済みメーカーを持つ場合はそれも含める
  defp assign_makers(socket, current_maker_id) do
    makers = Makers.all_makers()

    makers =
      if current_maker_id && not Enum.any?(makers, &(&1.id == current_maker_id)) do
        [Makers.get_maker!(current_maker_id) | makers]
      else
        makers
      end

    assign(socket, :makers, makers)
  end

  @impl true
  def handle_event("validate", %{"item" => params}, socket) do
    changeset =
      socket.assigns.item
      |> Items.change_item(locked_params(socket, params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"item" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      save(socket, socket.assigns.live_action, locked_params(socket, params))
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  # 無効にした入力欄は送信されない。ロック中は現在の値を使う(サーバー側でも変更は拒否される)
  defp locked_params(%{assigns: %{locked?: true, item: item}}, params) do
    Map.merge(params, %{
      "units_per_case" => to_string(item.units_per_case),
      "expiration_type" => to_string(item.expiration_type)
    })
  end

  defp locked_params(_socket, params), do: params

  defp save(socket, :new, params) do
    socket.assigns.current_scope
    |> Items.create_item(params)
    |> handle_result(socket, "商品を登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> Items.update_item(socket.assigns.item, params)
    |> handle_result(socket, "商品を更新しました。", :update)
  end

  defp handle_result({:ok, item}, socket, message, category) do
    OperationLog.info(socket, message, category, item)
    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/items")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category),
    do: {:noreply, assign_form(socket, changeset)}

  defp handle_result({:error, :lots_exist}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "ロットがあるため、ケース入数と期限区分は変更できません。")}

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: "item"))
end
