defmodule FoodShip.InventoryStub do
  @moduledoc """
  在庫 API(`FoodShip.Inventory.Client`)のテスト用スタブ。`Req.Test` の `plug` 関数と、
  在庫 API の応答(JSON 本文)の組み立てを提供する。

      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 201, InventoryStub.order()) end)

  `Task` から呼ばれるテストでは、`async: false` にして `setup {Req.Test, :set_req_test_from_context}`
  で共有モードにする。
  """

  @doc "スタブを登録する(`fun` は `conn` を受けて `conn` を返す)。"
  def stub(fun), do: Req.Test.stub(FoodShip.Inventory.Client, fun)

  @doc "通信失敗(タイムアウト)を返すスタブ。"
  def timeout(conn), do: Req.Test.transport_error(conn, :timeout)

  @doc "JSON 応答。"
  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  @doc "エラー応答(共通形式 `error`・`message` ＋付加情報)。"
  def error(conn, status, code, extra \\ %{}) do
    json(conn, status, Map.merge(extra, %{"error" => code, "message" => code}))
  end

  @doc """
  共通のオーダー表現(JSON の文字列キー)。

  `attrs`: `:order_id`・`:external_slip_id`・`:status`・`:shipped_at`・`:item_id`・
  `:req_pieces`・`:allocations`(`[{lot_id, expiration_date, pieces}]`)。
  """
  def order(attrs \\ %{}) do
    attrs = Map.new(attrs)
    req_pieces = Map.get(attrs, :req_pieces, 3)

    allocations =
      attrs
      |> Map.get(:allocations, [{"01JE0000000000000000000001", "2026-12-20", req_pieces}])
      |> Enum.map(fn {lot_id, expiration_date, pieces} ->
        %{
          "lot_id" => lot_id,
          "expiration_date" => expiration_date,
          "allocated_cases" => 0,
          "allocated_pieces" => pieces
        }
      end)

    %{
      "order_id" => Map.get(attrs, :order_id, "01JD0000000000000000000001"),
      "external_slip_id" => Map.get(attrs, :external_slip_id, "01JB0000000000000000000001"),
      "warehouse_id" => "01JA0000000000000000000000",
      "shipment_date" => Map.get(attrs, :shipment_date, "2026-11-15"),
      "status" => Map.get(attrs, :status, "allocated"),
      "shipped_at" => Map.get(attrs, :shipped_at),
      "lines" => [
        %{
          "item_id" => Map.get(attrs, :item_id, "01JC0000000000000000000001"),
          "req_cases" => 0,
          "req_pieces" => req_pieces,
          "min_expiration_date" => Map.get(attrs, :min_expiration_date),
          "allocations" => allocations
        }
      ]
    }
  end
end
