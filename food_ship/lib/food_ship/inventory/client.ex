defmodule FoodShip.Inventory.Client do
  @moduledoc """
  在庫システムの API(`/api/v1`)を呼ぶクライアント。DB を持たない外部境界で、テストでは
  `Req.Test` のスタブに差し替えてよい唯一の境界。

  - 認証は `Authorization: Bearer <token>`。トークンはログに出さない
  - 状態を変える呼び出し(引当・確定・解除)は `operator` を必ず付ける
  - リトライは `retry: :transient`(接続エラー・タイムアウト・408/429/500/502/503/504)で、
    最大 3 回、待機 1・2・4 秒。401/404/409/422 は再試行しない
  - 応答は、成功・在庫不足・各エラー・通信失敗を判別できるタグ付きタプルに変換する

  ## エラー

    * `{:error, :unauthorized}` - 401
    * `{:error, :not_found}` - 404
    * `{:error, :invalid_state}` - 409
    * `{:error, :idempotency_conflict, %{order_id: _, status: _}}` - 409
    * `{:error, :insufficient_stock, [%{item_id: _, shortage_cases: _, shortage_pieces: _}]}` - 422
    * `{:error, :validation_failed, [%{path: _, message: _}]}` - 422
    * `{:error, :connection}` - 通信失敗・リトライ後も続く 5xx・想定外の応答
    * `{:error, :warehouse_not_configured}` - デフォルト倉庫が未設定(`default_warehouse_id/1` のみ)

  設定は `runtime.exs` で `FoodShip.Inventory.Client` をキーに集約し、実行時に読む。
  """

  use FoodShip.Utils.Logger

  @statuses %{
    "allocated" => :allocated,
    "shipped" => :shipped,
    "cancelled" => :cancelled,
    "reversed" => :reversed
  }

  @orders_path "/api/v1/shipment_orders"
  @warehouses_path "/api/v1/warehouses"

  @doc """
  ① 出庫引当。

  `params` は `warehouse_id`・`shipment_date`(`Date`)・`external_slip_id`・`operator`・
  `lines`(`item_id`・`req_cases`・`req_pieces`・`min_expiration_date`)。
  新規は `{:ok, order, :created}`、冪等な再送は `{:ok, order, :replayed}`。
  """
  def allocate(params) do
    body = %{
      warehouse_id: params.warehouse_id,
      shipment_date: Date.to_iso8601(params.shipment_date),
      external_slip_id: params.external_slip_id,
      operator: params.operator,
      lines:
        Enum.map(params.lines, fn line ->
          %{
            item_id: line.item_id,
            req_cases: line.req_cases,
            req_pieces: line.req_pieces,
            min_expiration_date:
              line.min_expiration_date && Date.to_iso8601(line.min_expiration_date)
          }
        end)
    }

    case request(:post, @orders_path, json: body) do
      {:ok, 201, body} -> with {:ok, order} <- parse_order(body), do: {:ok, order, :created}
      {:ok, 200, body} -> with {:ok, order} <- parse_order(body), do: {:ok, order, :replayed}
      {:ok, _status, _body} -> {:error, :connection}
      error -> error
    end
  end

  @doc "② 出庫確定。すでに確定済みでも成功(冪等)。"
  def ship_order(order_id, operator) do
    order_request(:post, order_path(order_id, "ship"), json: %{operator: operator})
  end

  @doc "③ 引当解除。すでに解除済みでも成功(冪等)。`reason` は任意。"
  def cancel_order(order_id, operator, reason \\ nil) do
    body = %{operator: operator} |> maybe_put(:reason, reason)
    order_request(:post, order_path(order_id, "cancel"), json: body)
  end

  @doc "⑤ オーダーの照会(`:id`)。"
  def get_order(order_id), do: order_request(:get, order_path(order_id, nil), [])

  @doc "⑤ `external_slip_id` による照会。取消済みを含め新しい順。該当なしは `{:ok, []}`。"
  def list_orders_by_slip(external_slip_id) do
    case request(:get, @orders_path, params: [external_slip_id: external_slip_id]) do
      {:ok, 200, %{"shipment_orders" => orders}} when is_list(orders) ->
        parse_list(orders, &parse_order/1)

      {:ok, _status, _body} ->
        {:error, :connection}

      error ->
        error
    end
  end

  @doc "⑦ 商品コードで有効な商品を検索する(完全一致)。無ければ `{:error, :not_found}`。"
  def find_item(item_code) do
    case request(:get, "/api/v1/items", params: [item_code: item_code]) do
      {:ok, 200, %{"items" => items}} when is_list(items) ->
        items
        |> Enum.find(&(is_map(&1) and &1["item_code"] == item_code))
        |> parse_item()

      {:ok, _status, _body} ->
        {:error, :connection}

      error ->
        error
    end
  end

  @doc """
  ⑥ 対象倉庫(在庫側のデフォルト倉庫)の ID。

  在庫の倉庫画面で設定されたデフォルト倉庫を、呼び出しのたびに取得する(キャッシュしない)。
  デフォルト倉庫が無ければ `{:error, :warehouse_not_configured}`。

  `opts` は `Req` のオプション。画面表示のチェックでは `retry: false` を渡してリトライの待機を避ける。
  """
  def default_warehouse_id(opts \\ []) do
    case request(:get, @warehouses_path, opts) do
      {:ok, 200, %{"warehouses" => warehouses}} when is_list(warehouses) ->
        warehouses
        |> Enum.find(&(is_map(&1) and &1["is_default"] == true))
        |> parse_default_warehouse()

      {:ok, _status, _body} ->
        {:error, :connection}

      error ->
        error
    end
  end

  ## 要求

  defp order_request(method, path, opts) do
    case request(method, path, opts) do
      {:ok, 200, body} -> parse_order(body)
      {:ok, _status, _body} -> {:error, :connection}
      error -> error
    end
  end

  defp request(method, path, opts) do
    case Req.request(new(), [method: method, url: path] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        log(method, path, status)
        {:ok, status, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        log(method, path, status)
        error_from(status, body)

      {:error, exception} ->
        # 例外の内容(接続先など)は出さず、種別だけ記録する
        Logger.warning("在庫 API に接続できませんでした。", :api, %{
          method: method_name(method),
          path: path,
          reason: exception.__struct__
        })

        {:error, :connection}
    end
  end

  defp new do
    base_ms = config(:retry_base_ms) || 1000

    [
      base_url: config(:base_url),
      auth: {:bearer, config(:token)},
      connect_options: [timeout: config(:connect_timeout)],
      receive_timeout: config(:receive_timeout),
      retry: :transient,
      max_retries: 3,
      retry_delay: fn attempt -> base_ms * Integer.pow(2, attempt) end,
      retry_log_level: false
    ]
    |> Keyword.merge(config(:req_options) || [])
    |> Req.new()
  end

  defp log(method, path, status) when status in 200..299 or status in [401, 404, 409, 422] do
    Logger.info("在庫 API を呼び出しました。", :api, %{
      method: method_name(method),
      path: path,
      status: status
    })
  end

  defp log(method, path, status) do
    Logger.warning("在庫 API が想定外の応答を返しました。", :api, %{
      method: method_name(method),
      path: path,
      status: status
    })
  end

  defp method_name(method), do: method |> Atom.to_string() |> String.upcase()

  defp config(key), do: :food_ship |> Application.get_env(__MODULE__, []) |> Keyword.get(key)

  defp order_path(order_id, nil), do: "#{@orders_path}/#{URI.encode_www_form(order_id)}"

  defp order_path(order_id, action),
    do: "#{@orders_path}/#{URI.encode_www_form(order_id)}/#{action}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  ## エラー応答の変換

  defp error_from(401, _body), do: {:error, :unauthorized}
  defp error_from(404, _body), do: {:error, :not_found}

  defp error_from(409, %{"error" => "invalid_state"}), do: {:error, :invalid_state}

  defp error_from(409, %{"error" => "idempotency_conflict"} = body) do
    {:error, :idempotency_conflict,
     %{order_id: body["order_id"], status: Map.get(@statuses, body["status"])}}
  end

  defp error_from(422, %{"error" => "insufficient_stock", "shortages" => shortages})
       when is_list(shortages) do
    {:error, :insufficient_stock,
     Enum.map(shortages, fn shortage ->
       %{
         item_id: shortage["item_id"],
         shortage_cases: shortage["shortage_cases"] || 0,
         shortage_pieces: shortage["shortage_pieces"] || 0
       }
     end)}
  end

  defp error_from(422, %{"error" => "validation_failed"} = body) do
    errors = if is_list(body["errors"]), do: body["errors"], else: []

    {:error, :validation_failed,
     Enum.map(errors, fn error ->
       %{path: error["path"] || [], message: error["message"] || ""}
     end)}
  end

  defp error_from(_status, _body), do: {:error, :connection}

  ## 応答の変換

  defp parse_order(%{"order_id" => order_id, "status" => status} = body)
       when is_binary(order_id) do
    with {:ok, status} <- fetch_status(status),
         {:ok, shipment_date} <- parse_date(body["shipment_date"]),
         {:ok, shipped_at} <- parse_datetime(body["shipped_at"]),
         {:ok, lines} <- parse_list(body["lines"] || [], &parse_line/1) do
      {:ok,
       %{
         order_id: order_id,
         external_slip_id: body["external_slip_id"],
         warehouse_id: body["warehouse_id"],
         shipment_date: shipment_date,
         status: status,
         shipped_at: shipped_at,
         lines: lines
       }}
    end
  end

  defp parse_order(_body), do: {:error, :connection}

  defp parse_line(%{"item_id" => item_id} = line) do
    with {:ok, min_expiration_date} <- parse_date(line["min_expiration_date"]),
         {:ok, allocations} <- parse_list(line["allocations"] || [], &parse_allocation/1) do
      {:ok,
       %{
         item_id: item_id,
         req_cases: line["req_cases"],
         req_pieces: line["req_pieces"],
         min_expiration_date: min_expiration_date,
         allocations: allocations
       }}
    end
  end

  defp parse_line(_line), do: {:error, :connection}

  defp parse_allocation(%{"lot_id" => lot_id} = allocation) do
    with {:ok, %Date{} = expiration_date} <- parse_date(allocation["expiration_date"]) do
      {:ok,
       %{
         lot_id: lot_id,
         expiration_date: expiration_date,
         allocated_cases: allocation["allocated_cases"] || 0,
         allocated_pieces: allocation["allocated_pieces"] || 0
       }}
    end
  end

  defp parse_allocation(_allocation), do: {:error, :connection}

  defp parse_default_warehouse(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp parse_default_warehouse(nil), do: {:error, :warehouse_not_configured}
  defp parse_default_warehouse(_warehouse), do: {:error, :connection}

  defp parse_item(%{"id" => id} = item) do
    {:ok,
     %{
       id: id,
       item_code: item["item_code"],
       item_name: item["item_name"],
       maker_id: item["maker_id"],
       maker_name: item["maker_name"],
       units_per_case: item["units_per_case"],
       expiration_type: item["expiration_type"]
     }}
  end

  defp parse_item(nil), do: {:error, :not_found}
  defp parse_item(_item), do: {:error, :connection}

  defp fetch_status(status) do
    case Map.fetch(@statuses, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :connection}
    end
  end

  defp parse_date(nil), do: {:ok, nil}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :connection}
    end
  end

  defp parse_date(_value), do: {:error, :connection}

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :connection}
    end
  end

  defp parse_datetime(_value), do: {:error, :connection}

  # 全要素が成功したときだけ `{:ok, list}`。1 つでも失敗したら `{:error, :connection}`
  defp parse_list(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} -> {:halt, {:error, :connection}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_list(_list, _fun), do: {:error, :connection}
end
