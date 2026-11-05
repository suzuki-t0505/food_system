defmodule FoodShipWeb.ExpirationRuleLive.Index do
  @moduledoc "出荷期限ルールの一覧(全ロール参照)。登録・編集・削除は `admin` のみ。"

  use FoodShipWeb, :live_view

  alias FoodShip.ExpirationRules
  alias FoodShip.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        出荷期限ルール
        <:subtitle>最低許容期限日 = 出荷予定日 + 最低残日数。ルールが無い組み合わせは期限の制限なしです。</:subtitle>
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/expiration_rules/new"}
            class="btn btn-primary"
            id="new-expiration-rule"
          >
            ルールを登録する
          </.link>
        </:actions>
      </.header>

      <div class="overflow-x-auto">
        <table class="table" id="expiration-rules">
          <thead>
            <tr>
              <th>発注元</th>
              <th>商品</th>
              <th class="text-right">最低残日数</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @rules} id={"expiration-rule-#{rule.id}"}>
              <td>{rule.client.client_code} {rule.client.client_name}</td>
              <td>{rule.shipping_item.item_code} {rule.shipping_item.item_name}</td>
              <td class="text-right">{rule.min_remaining_days} 日</td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/expiration_rules/#{rule.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-expiration-rule-#{rule.id}"}
                >
                  編集
                </.link>
                <button
                  phx-click="delete"
                  phx-value-id={rule.id}
                  data-confirm="このルールを削除します。登録済みの伝票には影響しません。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"delete-expiration-rule-#{rule.id}"}
                >
                  削除
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
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :rules, ExpirationRules.list_expiration_rules())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      case ExpirationRules.delete_expiration_rule(
             socket.assigns.current_scope,
             ExpirationRules.get_expiration_rule!(id)
           ) do
        {:ok, rule} ->
          message = "ルールを削除しました。"
          OperationLog.info(socket, message, :delete, rule)

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> assign(:rules, ExpirationRules.list_expiration_rules())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "削除できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end
end
