defmodule FoodShipWeb.ShippingSlipLive.Form do
  @moduledoc """
  伝票の登録(`:new`)と、件数・出荷予定日の変更(`:edit`)。`staff` 以上。

  入力すると、箱数(手修正可)・出庫総数量(バラ。手修正不可)・最低許容期限日をリアルタイムに
  計算して表示する。保存は、先に `pending` で保存してから、在庫 API の引当を `Task` ＋
  `handle_info` で呼ぶ(通信失敗でも入力内容は消えない)。結果は作業画面に遷移して表示する。
  """

  use FoodShipWeb, :live_view

  alias FoodShip.{Clients, ShippingItems, ShippingSlips}
  alias FoodShip.ShippingSlips.ShippingSlip
  alias FoodShip.Utils.{ConvertDatetime, Permission}
  alias FoodShipWeb.SlipMessages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4">
        <.header>{@page_title}</.header>

        <div
          :if={!@warehouse_configured}
          id="warehouse-warning"
          role="alert"
          class="alert alert-warning"
        >
          対象倉庫が設定されていません。管理者に連絡してください。
        </div>

        <p :if={@saving} id="allocating" class="text-sm">在庫システムに引当を依頼しています…</p>

        <.form for={@form} id="shipping-slip-form" phx-change="validate" phx-submit="save">
          <fieldset disabled={@saving || !@warehouse_configured} class="space-y-1">
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
              label="商品"
              prompt="選択してください"
              options={@item_options}
              required
            />
            <dl :if={@live_action == :edit} class="mb-4 space-y-1 text-sm" id="slip-summary">
              <div class="flex gap-2">
                <dt class="font-semibold">伝票番号</dt>
                <dd>{ShippingSlip.slip_no_label(@slip)}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="font-semibold">発注元</dt>
                <dd>{@slip.client.client_code} {@slip.client.client_name}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="font-semibold">商品</dt>
                <dd>{@slip.shipping_item.item_code} {@slip.shipping_item.item_name}</dd>
              </div>
              <div :if={@slip.client_slip_no} class="flex gap-2">
                <dt class="font-semibold">発注元伝票番号</dt>
                <dd>{@slip.client_slip_no}</dd>
              </div>
            </dl>
            <.input field={@form[:scheduled_ship_date]} type="date" label="出荷予定日" required />
            <.input field={@form[:order_count]} type="number" min="1" label="件数" required />
            <.input
              :if={@live_action == :new}
              field={@form[:client_slip_no]}
              type="text"
              label="発注元伝票番号(任意)"
            />
            <.input
              field={@form[:box_count]}
              type="number"
              min="1"
              label="箱数(手修正できます)"
            />

            <dl id="slip-preview" class="my-4 space-y-1 rounded-box bg-base-200 p-3 text-sm">
              <div class="flex gap-2">
                <dt class="font-semibold">出庫総数量(バラ)</dt>
                <dd id="preview-total-piece-qty">
                  <%= if @preview.total_piece_qty do %>
                    {@preview.total_piece_qty} 個
                  <% else %>
                    -
                  <% end %>
                </dd>
              </div>
              <div class="flex gap-2">
                <dt class="font-semibold">最低許容期限日</dt>
                <dd id="preview-min-expiration-date">
                  <%= cond do %>
                    <% @preview.min_expiration_date -> %>
                      {@preview.min_expiration_date}(出荷予定日から {@preview.min_remaining_days} 日)
                    <% @preview.min_remaining_days -> %>
                      出荷予定日から {@preview.min_remaining_days} 日
                    <% true -> %>
                      制限なし
                  <% end %>
                </dd>
              </div>
            </dl>

            <div class="flex gap-2">
              <.button
                class="btn btn-primary"
                phx-disable-with="保存中..."
                data-confirm={confirm_message(@live_action, @slip)}
              >
                {if @live_action == :new, do: "登録して引き当てる", else: "変更して再引当する"}
              </.button>
              <.link navigate={back_path(@slip)} class="btn">キャンセル</.link>
            </div>
          </fieldset>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:saving, false)
      |> assign(:box_touched, false)
      |> assign(:warehouse_configured, ShippingSlips.warehouse_configured?())

    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    slip = %ShippingSlip{}
    params = %{"scheduled_ship_date" => Date.to_iso8601(ConvertDatetime.today_jst())}

    socket
    |> assign(:page_title, "伝票を登録する")
    |> assign(:slip, slip)
    |> assign(
      :client_options,
      Enum.map(Clients.all_clients(), &{"#{&1.client_code} #{&1.client_name}", &1.id})
    )
    |> assign(
      :item_options,
      Enum.map(ShippingItems.all_shipping_items(), &{"#{&1.item_code} #{&1.item_name}", &1.id})
    )
    |> assign_form_and_preview(slip, params)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    slip = ShippingSlips.get_shipping_slip!(id)

    if ShippingSlip.unpacked?(slip) do
      params = %{
        "scheduled_ship_date" => Date.to_iso8601(slip.scheduled_ship_date),
        "order_count" => to_string(slip.order_count),
        "box_count" => to_string(slip.box_count)
      }

      socket
      |> assign(:page_title, "伝票を変更する")
      |> assign(:slip, slip)
      |> assign_form_and_preview(slip, params)
    else
      socket
      |> put_flash(:error, "この伝票は変更できません。")
      |> push_navigate(to: back_path(slip))
    end
  end

  @impl true
  def handle_event("validate", %{"shipping_slip" => params} = event, socket) do
    touched = socket.assigns.box_touched or event["_target"] == ["shipping_slip", "box_count"]

    {:noreply,
     socket
     |> assign(:box_touched, touched)
     |> assign_form_and_preview(socket.assigns.slip, params,
       validate: true,
       target: event["_target"]
     )}
  end

  def handle_event("save", %{"shipping_slip" => params}, socket) do
    cond do
      !Permission.can?(socket.assigns.current_scope.user, :manage_shipping_slips) ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(:forbidden))}

      socket.assigns.saving ->
        {:noreply, socket}

      true ->
        save(socket, socket.assigns.live_action, params)
    end
  end

  @impl true
  def handle_info({:slip_result, :allocate, _id, result}, socket) do
    {kind, message} = SlipMessages.allocation_result(result)

    case result do
      {:ok, slip, _info} -> OperationLog.info(socket, "伝票を引き当てました。", :update, slip)
      _ -> :ok
    end

    {:noreply,
     socket
     |> put_flash(kind, message)
     |> push_navigate(to: date_path(socket.assigns.slip, result))}
  end

  defp save(socket, :new, params) do
    case ShippingSlips.create_shipping_slip(
           socket.assigns.current_scope,
           params
         ) do
      {:ok, slip} ->
        OperationLog.info(socket, "伝票を登録しました。", :create, slip)
        {:noreply, start_allocation(socket, slip)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(Map.put(changeset, :action, :validate), as: "shipping_slip")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(reason))}
    end
  end

  defp save(socket, :edit, params) do
    scope = socket.assigns.current_scope

    case ShippingSlips.update_shipping_slip(
           scope,
           socket.assigns.slip,
           params
         ) do
      {:ok, slip} ->
        OperationLog.info(socket, "伝票を変更しました。", :update, slip)
        {:noreply, start_allocation(socket, slip)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(Map.put(changeset, :action, :validate), as: "shipping_slip")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SlipMessages.error_message(reason))}
    end
  end

  # 保存済み(pending)の伝票の引当を Task で呼ぶ。操作ログ・画面遷移は結果を受ける handle_info で行う
  defp start_allocation(socket, slip) do
    pid = self()
    scope = socket.assigns.current_scope

    Task.start(fn ->
      send(
        pid,
        {:slip_result, :allocate, slip.id, ShippingSlips.allocate_shipping_slip(scope, slip)}
      )
    end)

    socket |> assign(:slip, slip) |> assign(:saving, true)
  end

  # フォームの値から計算結果を出し、箱数を手修正していなければ初期値を入れ直す
  defp assign_form_and_preview(socket, slip, params, opts \\ []) do
    preview = ShippingSlips.preview(preview_params(slip, params))
    params = maybe_default_box_count(socket, params, preview, opts[:target])

    changeset =
      slip
      |> ShippingSlips.change_shipping_slip(params)
      |> then(&if(opts[:validate], do: Map.put(&1, :action, :validate), else: &1))

    socket
    |> assign(:preview, preview)
    |> assign(:form, to_form(changeset, as: "shipping_slip"))
  end

  # 変更画面は、発注元・商品が固定なので、伝票の値をプレビューに渡す
  defp preview_params(%ShippingSlip{id: nil}, params), do: params

  defp preview_params(%ShippingSlip{} = slip, params) do
    Map.merge(params, %{
      "client_id" => slip.client_id,
      "shipping_item_id" => slip.shipping_item_id
    })
  end

  # 箱数は、手修正するまでは「件数 × 標準箱数」を自動で入れる。変更画面では、登録済みの箱数を
  # 守るため、件数を変えたときだけ入れ直す
  defp maybe_default_box_count(socket, params, preview, target) do
    cond do
      socket.assigns.box_touched ->
        params

      socket.assigns.live_action == :edit and target != ["shipping_slip", "order_count"] ->
        params

      preview.default_box_count ->
        Map.put(params, "box_count", to_string(preview.default_box_count))

      true ->
        Map.put(params, "box_count", "")
    end
  end

  defp confirm_message(:new, _slip), do: nil

  defp confirm_message(:edit, %ShippingSlip{status: :allocated}),
    do: "件数・出荷予定日を変更します。在庫不足の場合、現在の引当は解除されます。よろしいですか?"

  defp confirm_message(:edit, _slip), do: "件数・出荷予定日を変更します。よろしいですか?"

  defp back_path(%ShippingSlip{scheduled_ship_date: %Date{} = date}),
    do: ~p"/shipping_slips?#{%{date: Date.to_iso8601(date)}}"

  defp back_path(_slip), do: ~p"/shipping_slips"

  # 結果の伝票の出荷予定日のタブへ。得られなければ、保存した伝票の日付
  defp date_path(slip, {:ok, %ShippingSlip{} = result, _info}),
    do: back_path(%{slip | scheduled_ship_date: result.scheduled_ship_date})

  defp date_path(slip, _result), do: back_path(slip)
end
