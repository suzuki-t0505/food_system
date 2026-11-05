defmodule FoodShipWeb.ClientLive.Index do
  @moduledoc "発注元の一覧(全ロール参照)。登録・編集・アーカイブ・復帰は `admin` のみ。"

  use FoodShipWeb, :live_view

  import FoodShipWeb.MasterComponents

  alias FoodShip.Clients
  alias FoodShip.Clients.Client
  alias FoodShip.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        発注元
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/clients/new"}
            class="btn btn-primary"
            id="new-client"
          >
            発注元を登録する
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
        <table class="table" id="clients">
          <thead>
            <tr>
              <th>コード</th>
              <th>名称</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={client <- @clients} id={"client-#{client.id}"}>
              <td>{client.client_code}</td>
              <td>{client.client_name}</td>
              <td><.archived_badge archived_at={client.archived_at} /></td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/clients/#{client.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-client-#{client.id}"}
                >
                  編集
                </.link>
                <button
                  :if={!Client.archived?(client)}
                  phx-click="archive"
                  phx-value-id={client.id}
                  data-confirm="この発注元をアーカイブします。新規伝票の選択肢に出なくなります。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-client-#{client.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={Client.archived?(client)}
                  phx-click="restore"
                  phx-value-id={client.id}
                  class="btn btn-sm"
                  id={"restore-client-#{client.id}"}
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
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, params) |> assign_clients()}
  end

  @impl true
  def handle_event("toggle_archived", _params, socket) do
    params =
      case socket.assigns.params do
        %{"include_archived" => "true"} = p -> Map.delete(p, "include_archived")
        p -> Map.put(p, "include_archived", "true")
      end

    {:noreply, push_patch(socket, to: ~p"/masters/clients?#{params}")}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    change(socket, id, &Clients.archive_client/2, "発注元をアーカイブしました。")
  end

  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, &Clients.restore_client/2, "発注元を復帰しました。")
  end

  defp change(socket, id, fun, message) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      case fun.(socket.assigns.current_scope, Clients.get_client!(id)) do
        {:ok, client} ->
          OperationLog.info(socket, message, :update, client)
          {:noreply, socket |> put_flash(:info, message) |> assign_clients()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "変更できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp assign_clients(socket),
    do: assign(socket, :clients, Clients.list_clients(socket.assigns.params))
end
