defmodule FoodVaultWeb.Management.MakerLive.Form do
  @moduledoc "メーカーの登録(`:new`)と編集(`:edit`)。`admin` のみ。"

  use FoodVaultWeb, :live_view

  alias FoodVault.Makers
  alias FoodVault.Makers.Maker
  alias FoodVault.Utils.Permission

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>{@page_title}</.header>

        <.form for={@form} id="maker-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:maker_code]} type="text" label="メーカーコード" required />
          <.input field={@form[:maker_name]} type="text" label="メーカー名" required />
          <div class="flex gap-2">
            <.button class="btn btn-primary" phx-disable-with="保存中...">保存する</.button>
            <.link navigate={~p"/masters/makers"} class="btn">キャンセル</.link>
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
    |> assign(:page_title, "メーカーを登録する")
    |> assign(:maker, %Maker{})
    |> assign_form(Makers.change_maker(%Maker{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    maker = Makers.get_maker!(id)

    socket
    |> assign(:page_title, "メーカーを編集する")
    |> assign(:maker, maker)
    |> assign_form(Makers.change_maker(maker))
  end

  @impl true
  def handle_event("validate", %{"maker" => params}, socket) do
    changeset = socket.assigns.maker |> Makers.change_maker(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"maker" => params}, socket) do
    if Permission.can?(socket.assigns.current_scope.user, :manage_masters) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "権限がありません。")}
    end
  end

  defp save(socket, :new, params) do
    socket.assigns.current_scope
    |> Makers.create_maker(params)
    |> handle_result(socket, "メーカーを登録しました。", :create)
  end

  defp save(socket, :edit, params) do
    socket.assigns.current_scope
    |> Makers.update_maker(socket.assigns.maker, params)
    |> handle_result(socket, "メーカーを更新しました。", :update)
  end

  defp handle_result({:ok, maker}, socket, message, category) do
    OperationLog.info(socket, message, category, maker)

    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/masters/makers")}
  end

  defp handle_result({:error, %Ecto.Changeset{} = changeset}, socket, _message, _category),
    do: {:noreply, assign_form(socket, changeset)}

  defp handle_result({:error, :forbidden}, socket, _message, _category),
    do: {:noreply, put_flash(socket, :error, "権限がありません。")}

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: "maker"))
end
