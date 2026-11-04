defmodule FoodVaultWeb.Api.V1.ShipmentOrderController do
  @moduledoc """
  出庫オーダーの在庫 API(① 出庫引当、② 出庫確定、③ 引当解除、⑤ 照会)。

  状態を変える API は `operator` が必須で、`{:api, operator}` の actor として Context に渡す。
  成功したときだけ `OperationLog` を残す(冪等な再送では残さない)。
  """

  use FoodVaultWeb, :controller

  alias FoodVault.ShipmentOrders
  alias FoodVaultWeb.Api.Operator

  action_fallback FoodVaultWeb.Api.FallbackController

  @doc "① 出庫引当。新規は 201、`external_slip_id` の冪等な再送は 200。"
  def create(conn, params) do
    with {:ok, operator} <- Operator.fetch(params),
         {:ok, %{shipment_order: order, replayed?: replayed?}} <-
           ShipmentOrders.allocate_shipment_order({:api, operator}, params) do
      conn = assign(conn, :api_operator, operator)
      unless replayed?, do: OperationLog.info(conn, "出庫オーダーを引き当てました。", :create, order)

      conn
      |> put_status(if replayed?, do: 200, else: 201)
      |> render(:show, order: order)
    end
  end

  @doc "⑤ 状態・引当結果の照会(`:id`)。"
  def show(conn, %{"id" => id}) do
    with {:ok, order} <- ShipmentOrders.fetch_shipment_order(id) do
      render(conn, :show, order: order)
    end
  end

  @doc "⑤ `?external_slip_id=` による照会(取消済みを含め新しい順。該当なしは空配列)。"
  def index(conn, %{"external_slip_id" => slip_id}) when is_binary(slip_id) do
    slip_id = String.trim(slip_id)

    cond do
      slip_id == "" ->
        {:error, :validation_failed, [slip_id_error("を指定してください")]}

      String.length(slip_id) > 255 ->
        {:error, :validation_failed, [slip_id_error("は 255 文字以内で指定してください")]}

      true ->
        render(conn, :index, orders: ShipmentOrders.list_shipment_orders_by_slip(slip_id))
    end
  end

  def index(_conn, _params) do
    {:error, :validation_failed, [slip_id_error("を指定してください")]}
  end

  defp slip_id_error(message), do: %{path: ["external_slip_id"], message: message}
end
