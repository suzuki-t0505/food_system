defmodule FoodShip.InventoryStub do
  @moduledoc """
  在庫 API(`FoodShip.Inventory.Client`)のテスト用スタブ。`Req.Test` の `plug` 関数と、
  在庫 API の応答(JSON 本文)の組み立てを提供する。

      InventoryStub.stub(fn conn -> InventoryStub.json(conn, 201, InventoryStub.order()) end)

  `Task` から呼ばれるテストでは、`async: false` にして `setup {Req.Test, :set_req_test_from_context}`
  で共有モードにする。

  発送は引当のたびに在庫のデフォルト倉庫(`GET /api/v1/warehouses`)を取得する。伝票を作る・
  画面を開くテストは、`setup` で `stub_defaults/0` を呼んでおく(以降の `routes/1` は、倉庫の
  ルートが無ければ既定のデフォルト倉庫で応答する)。
  """

  @warehouses_path "/api/v1/warehouses"
  @default_warehouse_id "01JA0000000000000000000000"

  @doc "既定のデフォルト倉庫の ID。"
  def default_warehouse_id, do: @default_warehouse_id

  @doc """
  倉庫一覧(`GET /api/v1/warehouses`)の応答本文。既定は、デフォルト倉庫が 1 つある一覧。

  `default?: false` ならデフォルト倉庫が無い一覧(倉庫はあるが、どれもデフォルトではない)。
  """
  def warehouses(opts \\ []) do
    default? = Keyword.get(opts, :default?, true)

    %{
      "warehouses" => [
        %{
          "id" => @default_warehouse_id,
          "warehouse_code" => "W01",
          "warehouse_name" => "第1倉庫",
          "is_default" => default?
        },
        %{
          "id" => "01JA0000000000000000000001",
          "warehouse_code" => "W02",
          "warehouse_name" => "第2倉庫",
          "is_default" => false
        }
      ]
    }
  end

  @doc "デフォルト倉庫がある応答を返す。"
  def default_warehouse(conn), do: json(conn, 200, warehouses())

  @doc "デフォルト倉庫が無い応答を返す。`routes/1` に `{\"GET\", \"/api/v1/warehouses\", &without_default_warehouse/1}` で渡す。"
  def without_default_warehouse(conn), do: json(conn, 200, warehouses(default?: false))

  @doc """
  倉庫の取得だけに応じるスタブ(それ以外の呼び出しは例外)。`setup` で呼び、伝票の作成や画面の表示で
  デフォルト倉庫の取得が走っても、スタブが無くて落ちないようにする。
  """
  def stub_defaults, do: routes([])

  @doc "スタブを登録する(`fun` は `conn` を受けて `conn` を返す)。"
  def stub(fun), do: Req.Test.stub(FoodShip.Inventory.Client, fun)

  @doc """
  メソッド・パスで応答を振り分けるスタブ。`routes` は `{method, path, fun}` のリストで、
  `path` は文字列(完全一致)か正規表現。最初に一致したものを使い、一致しなければ例外にする
  (想定外の API 呼び出しをテストで検出する)。

  呼び出しごとに `{:inventory_call, method, path, body}` をテストプロセスへ送る(`calls/0` で取り出す)。
  デコード済みのリクエスト本文は `conn.assigns.body`(本文なしは `nil`)で参照できる。

  デフォルト倉庫の取得(`GET /api/v1/warehouses`)は、`routes` に指定が無ければ既定の応答
  (`default_warehouse/1`)で処理し、`calls/0` には含めない(引当などの呼び出し順の検証に影響しない)。
  `routes` に指定があれば、それを使い、`calls/0` にも含める。
  """
  def routes(routes) do
    pid = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      # 応答側で参照できるように、デコード済みのリクエスト本文を assigns に入れる
      conn = Plug.Conn.assign(conn, :body, body)

      dispatch(routes, conn, pid, body)
    end)
  end

  defp dispatch(routes, conn, pid, body) do
    case Enum.find(routes, fn {method, path, _fun} -> route_match?(conn, method, path) end) do
      {_method, _path, fun} ->
        send(pid, {:inventory_call, conn.method, conn.request_path, body})
        fun.(conn)

      nil ->
        if conn.method == "GET" and conn.request_path == @warehouses_path do
          default_warehouse(conn)
        else
          send(pid, {:inventory_call, conn.method, conn.request_path, body})
          raise "想定外の在庫 API 呼び出し: #{conn.method} #{conn.request_path}"
        end
    end
  end

  defp route_match?(conn, method, %Regex{} = path),
    do: conn.method == method and Regex.match?(path, conn.request_path)

  defp route_match?(conn, method, path), do: conn.method == method and conn.request_path == path

  @doc "`routes/1` のスタブへ送られた呼び出しを、呼ばれた順に `{method, path, body}` で返す。"
  def calls(acc \\ []) do
    receive do
      {:inventory_call, method, path, body} -> calls([{method, path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

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
      "warehouse_id" => @default_warehouse_id,
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
