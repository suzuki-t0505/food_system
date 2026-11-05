defmodule FoodShipWeb.Management.ExpirationRuleLive.Form do
  @moduledoc """
  出荷期限ルールの登録(`:new`)と編集(`:edit`)。`admin` のみ。

  編集は最低残日数だけ(発注元・商品は変えられない)。選択肢はアーカイブ済みを含まない。
  """

  use FoodShipWeb, :live_view

  alias FoodShip.{Clients, ExpirationRules, ShippingItems}
  alias FoodShip.ExpirationRules.ExpirationRule
  alias FoodShip.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4">
        <.header>{@page_title}</.header>

        <.form for={@form} id="expiration-rule-form" phx-change="validate" phx-submit="save">
          <.input
            :if={@live_action == :new}
            field={@form[:client_id]}
            type="select"
            label="発注元"
            prompt="選択してください"
            options={@client_options}
            required
          />
          <.input
            :if={@live_action == :new}
            field={@form[:shipping_item_id]}
            type="select"
            label="発送商品"
            prompt="選択してください"
            options={@item_options}
            required
          />
          <dl :if={@live_action == :edit} class="mb-4 space-y-1 text-sm">
            <div class="flex gap-2">
              <dt class="font-semibold">発注元</dt>
              <dd>{@rule.client.client_code} {@rule.client.client_name}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-semibold">発送商品</dt>
              <dd>{@rule.shipping_item.item_code} {@rule.shipping_item.item_name}</dd>
            </div>
          </dl>
          <.input
            field={@form[:min_remaining_days]}
            type="number"
            min="0"
            label="最低残日数(出荷予定日から数えて、この日数以上残っている商品だけ引き当てる)"
            required
          />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/expiration_rules"} class="btn">キャンセル</.link>
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
    |> assign(:page_title, "出荷期限ルールを登録する")
    |> assign(:rule, %ExpirationRule{})
    |> assign(
      :client_options,
      Enum.map(Clients.all_clients(), &{"#{&1.client_code} #{&1.client_name}", &1.id})
    )
    |> assign(
      :item_options,
      Enum.map(ShippingItems.all_shipping_items(), &{"#{&1.item_code} #{&1.item_name}", &1.id})
    )
    |> assign_form(ExpirationRules.change_expiration_rule(%ExpirationRule{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = ExpirationRules.get_expiration_rule!(id)

    socket
    |> assign(:page_title, "出荷期限ルールを編集する")
    |> assign(:rule, rule)
    |> assign_form(ExpirationRules.change_expiration_rule(rule))
  end

  @impl true
  def handle_event("validate", %{"expiration_rule" => params}, socket) do
    changeset =
      socket.assigns.rule
      |> ExpirationRules.change_expiration_rule(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"expiration_rule" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :new, params) do
    socket.assigns.current_scope
    |> ExpirationRules.create_expiration_rule(params)
    |> handle_result(socket, "ルールを登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> ExpirationRules.update_expiration_rule(socket.assigns.rule, params)
    |> handle_result(socket, "ルールを更新しました。", :update)
  end

  defp handle_result({:ok, rule}, socket, message, category) do
    OperationLog.info(socket, message, category, rule)

    {:noreply,
     socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/expiration_rules")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category),
    do: {:noreply, assign_form(socket, changeset)}

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: "expiration_rule"))
end
