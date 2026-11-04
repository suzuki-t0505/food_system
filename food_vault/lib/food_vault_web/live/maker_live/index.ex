defmodule FoodVaultWeb.MakerLive.Index do
  @moduledoc "メーカー一覧(全ロール参照)。アーカイブ・復帰は `admin` のみ。"

  use FoodVaultWeb, :live_view

  import FoodVaultWeb.InventoryComponents

  alias FoodVault.Makers
  alias FoodVault.Makers.Maker
  alias FoodVault.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        メーカー
        <:actions>
          <.link
            :if={Permission.can?(@current_scope.user, :manage_masters)}
            navigate={~p"/management/makers/new"}
            class="btn btn-primary"
            id="new-maker"
          >
            メーカーを登録する
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
        <table class="table" id="makers">
          <thead>
            <tr>
              <th>コード</th>
              <th>名称</th>
              <th>状態</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={maker <- @page.entries} id={"maker-#{maker.id}"}>
              <td>{maker.maker_code}</td>
              <td>{maker.maker_name}</td>
              <td><.archived_badge archived_at={maker.archived_at} /></td>
              <td
                :if={Permission.can?(@current_scope.user, :manage_masters)}
                class="space-x-2 text-right"
              >
                <.link
                  navigate={~p"/management/makers/#{maker.id}/edit"}
                  class="btn btn-sm"
                  id={"edit-maker-#{maker.id}"}
                >
                  編集
                </.link>
                <button
                  :if={!Maker.archived?(maker)}
                  phx-click="archive"
                  phx-value-id={maker.id}
                  data-confirm="このメーカーをアーカイブします。よろしいですか?"
                  class="btn btn-sm btn-error btn-soft"
                  id={"archive-maker-#{maker.id}"}
                >
                  アーカイブ
                </button>
                <button
                  :if={Maker.archived?(maker)}
                  phx-click="restore"
                  phx-value-id={maker.id}
                  class="btn btn-sm"
                  id={"restore-maker-#{maker.id}"}
                >
                  復帰
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.pagination page={@page} base_path={~p"/masters/makers"} params={@params} />
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

    {:noreply, push_patch(socket, to: ~p"/masters/makers?#{Map.delete(params, "page")}")}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    change(socket, id, &Makers.archive_maker/2, "メーカーをアーカイブしました。")
  end

  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, &Makers.restore_maker/2, "メーカーを復帰しました。")
  end

  defp change(socket, id, fun, message) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      case fun.(socket.assigns.current_scope, Makers.get_maker!(id)) do
        {:ok, maker} ->
          OperationLog.info(socket, message, :update, maker)
          {:noreply, socket |> put_flash(:info, message) |> assign_page()}

        {:error, :has_active_items} ->
          {:noreply, put_flash(socket, :error, "有効な商品があるため、アーカイブできません。")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "変更できませんでした。")}
      end
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp assign_page(socket), do: assign(socket, :page, Makers.list_makers(socket.assigns.params))
end
