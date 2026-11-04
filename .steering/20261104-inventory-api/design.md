# 設計: 在庫 API(段階 3)

要求は [requirements.md](requirements.md)。対象は `food_vault` のみ。以下 `{App}` は `FoodVault`。作業単位 A〜D の順に実装し、単位ごとに品質ゲートを通してコミットする。

## 1. 現状(調査結果)

- `router.ex` に `pipeline :api`(`accepts ["json"]` のみ)があるが、使うスコープは無い。`/api/v1` のルート・Controller・認証は無い
- `ShipmentOrders` Context は段階 2 で完成している。`allocate_shipment_order/2`・`ship_shipment_order/2`・`cancel_shipment_order/3` は actor に `{:api, operator}` を受け付け(`Permission.authorize/2` は許可、`authorize_origin` も許可)、冪等・競合の再比較も済み
- **API に足りない Context の口が 3 つある**:
  1. `get_shipment_order!/1` は `Repo.get!` で、存在しない ID は例外、ULID 形式でない文字列は `Ecto.Query.CastError`(500 になる)
  2. `external_slip_id` で複数件を引く関数が無い(`get_active_order_by_slip/1` は private で `cancelled` を除く 1 件のみ)
  3. 冪等の不一致が `{:error, :idempotency_conflict}` で、**既存オーダーの `order_id`・`status` を返せない**(§7.4 の 409 の付加情報、architecture §7.3 の `{:error, :idempotency_conflict, order}`)
- `Items`・`Warehouses` に有効なものの一覧(`all_items/0`・`all_warehouses/0`、コード順、メーカー preload 済み)はある。`item_code` での絞り込みは無い
- `Endpoint` の `Plug.Parsers` は JSON を受け付ける。**壊れた JSON は `Plug.Parsers.ParseError`(400)になり、`Accept` ヘッダが無い/`*/*` のリクエストでは `render_errors` が html を選んで `ErrorHTML` を返す**(API なのに HTML になる)。存在しないルート(`NoRouteError`)も同じ
- `ErrorJSON` の既定は `%{errors: %{detail: ...}}`(共通エラー形式と違う)。テストは `async: true` の 2 件のみ
- `OperationLog.info/4` は `conn` を受け付けるが、操作者は `current_scope` からしか取れず、API の `operator` は `nil` になる
- `Utils.Logger` に `:api` カテゴリは定義済み。`redact_keys` に `token` がある
- テスト基盤: `ConnCase`(ブラウザ用セッションのヘルパーのみ)、`ConcurrencyCase`(`sandbox: false`、`concurrently/2`)、`shipment_orders_fixtures.ex`(`order_fixture`)、`masters_fixtures.ex`
- 実行環境: `docker compose` はビルドできない。段階 2 と同様に、`elixir:1.20.5-otp-29` と `postgres:15.2` のコンテナを `--network host` で直接起動し、`/root/.ccr/ca-bundle.crt` を `SSL_CERT_FILE`・`HEX_CACERTS_PATH` に設定して品質ゲートを実行する(tasklist に手順を残す)

## 2. 方針

| 項目 | 決定 | 理由 |
| :-- | :-- | :-- |
| 業務ロジック | 変更しない。Context に足すのは上記 3 つの口(参照 2 つと冪等不一致の戻り値)と `Items` の検索のみ | 段階 2 で固めた挙動(ロック・冪等)を壊さない |
| Controller の責務 | `operator` の取り出し → Context 呼び出し → `render`/`FallbackController`。`Repo`・スキーマを直接触らない | architecture §2.2 |
| 認証方式の隔離 | トークンの照合は `ServiceTokenAuth.valid_token?/1` の **1 関数**に閉じ込める。Controller・Context は認証方式を知らない | 将来の DB 発行・有効期限への差し替え(requirements のスコープ外)に備える |
| トークンの設定 | `config :food_vault, FoodVaultWeb.Plugs.ServiceTokenAuth, tokens: [...]`(モジュール名をキーに `runtime.exs` に集約、coding-rules §13.2)。plug は **実行時**に `Application.get_env` で読む(コンパイル時に固定しない) | 秘密情報は `runtime.exs` |
| dev / test のトークン | dev は `runtime.exs` で `INVENTORY_API_TOKENS \|\| "dev-inventory-api-token"`(`INITIAL_ADMIN_*` と同じ形)。test は `config/test.exs` に `"test-inventory-api-token"` | 本番だけ必須にする。発送側の dev も同じ値を使える |
| 本番で未設定 | `runtime.exs` の `prod` で、`INVENTORY_API_TOKENS` が未設定、またはカンマ分割・trim 後に空なら `raise` | 起動時に落とす(§7.1) |
| 比較 | 設定の全トークンと `Plug.Crypto.secure_compare/2` で比べ、**短絡せず全て比較**してから any を取る(一致位置がタイミングに出ない)。ヘッダは `Bearer <token>`(スキームは大文字小文字を区別しない) | 定数時間比較 |
| 401 | `{ "error": "unauthorized", "message": "..." }` と `www-authenticate: Bearer` ヘッダ。`halt`。失敗は `Logger.warning(..., :api, %{path: ...})` で記録(ヘッダ・トークンは出さない) | §7.4 |
| エラー形式 | `FoodVaultWeb.Api.ErrorResponse.body(code, message, extra \\ %{})` に 1 か所で作る。`ServiceTokenAuth`・`FallbackController`・`ErrorJSON` が使う | 共通形式の取りこぼしを防ぐ |
| `ErrorJSON` | `render/2` を共通形式に置き換える(`"404.json"` → `%{error: "not_found", message: ...}`、`"400"` → `bad_request`、`"406"` → `not_acceptable`、`"415"` → `unsupported_media_type`、`"500"` → `internal_server_error`、その他は `status_message_from_template` のスネークケース)。アプリの JSON を返す先は API だけなので既定形式を差し替えてよい | architecture §7.3 は FallbackController だけを挙げるが、ルーティング前に起きる 404 / 400 は Endpoint 経由で `ErrorJSON` に来るため |
| API の format 固定 | Endpoint の `Plug.Parsers` の**前**に `FoodVaultWeb.Plugs.ApiFormat` を置く。`/api/` で始まるパスだけ `Phoenix.Controller.put_format(conn, "json")` する | `Accept` が無くても壊れた JSON・存在しないルートを JSON で返す |
| 入力 | `conn.params`(JSON ボディ + パス)を `Request.normalize/1` にそのまま渡す。`lines` はリスト、ID・日付は文字列。`operator` だけ Controller で検証する | `Request` は文字列キーを受け付け、`%{path, message}` の `errors` を返す |
| `operator` の検証 | `FoodVaultWeb.Api.Operator.fetch(params)`(新規)。文字列・trim 後に空でない・255 文字以内。違反は `{:error, :validation_failed, [%{path: ["operator"], message: "..."}]}`。他の項目のエラーと**合算しない**(operator 不正のときは Context を呼ばない) | 簡潔さ優先。複数エラーの同時返却は `Request` の `errors` の範囲内に留める |
| `reason`(③) | 任意。指定時は文字列で 255 文字以内、違反は 422。空文字・空白のみは `nil` | `shipment_order_events.reason` は `string` |
| 操作ログ | 書き込みの**成功時(`replayed?: false`)のみ** `OperationLog.info(conn, ..., :create/:update, order)`。`conn.assigns.api_operator` に `operator` を入れ、`OperationLog` の `operator/1` は `current_scope` が無いとき `api_operator` を使うように拡張する(最小変更) | 「誰が」が API でも残る。冪等再送では書かない(`Task` ではないので Controller で呼ぶ) |
| ページング | ⑥⑦ にページングは付けない(応答は `warehouses` / `items` のキー付き配列のみ。§7.2)。⑤ の `?external_slip_id=` も全件 | 仕様どおり。件数は少ない |
| ④ 出庫取消 | ルートを作らない(段階 5)。`POST .../reverse` は共通形式の 404 になる | スコープ外 |
| `Ecto.Changeset` の変換 | `FallbackController` に `{:error, %Ecto.Changeset{}}` の節を**作らない**。今回の Context は changeset を返さない(`validation_failed` のリスト形式) | 不要なコードを作らない |

## 3. 変更するファイル

### 3.1 Context(最小の追加)

`lib/food_vault/shipment_orders.ex`:

| 変更 | 内容 |
| :-- | :-- |
| `fetch_shipment_order(id)`(新規) | `{:ok, order}` / `{:error, :not_found}`。`Ecto.ULID.cast/1` が `:error` なら `:not_found`、存在しなければ `:not_found`。preload は `get_shipment_order!/1` と同じ(共通の private クエリに切り出す) |
| `list_shipment_orders_by_slip(external_slip_id)`(新規) | `external_slip_id` 一致の全件(`cancelled` を含む)を新しい順(`inserted_at desc, id desc`)。preload は同上。空文字・255 文字超は呼び出し側で弾く(Controller)。該当なしは `[]` |
| `{:error, :idempotency_conflict}` → `{:error, :idempotency_conflict, existing_order}`(変更) | `replay_result/2` が既存オーダー(`id`・`status` を持つ構造体)を返す。`resolve_duplicate` の再試行後も見つからない稀なケース(勝った側がその間に 2 回取消された)だけ、既存が無いので `{:error, :idempotency_conflict, nil}` を返す(API は付加情報なしの 409)。`@doc` と moduledoc を更新。既存テスト 1 件(`shipment_orders_test.exs:438`)の期待値を更新 |

`lib/food_vault/items.ex`: `search_active_items(item_code)`(新規)。有効な商品のみ、`item_code` が空・nil なら全件、指定時は**完全一致**。コード順、メーカー preload。`all_items/0` を内部で再利用する(絞り込み条件のみ足す)。

### 3.2 設定・認証

| ファイル | 内容 |
| :-- | :-- |
| `config/runtime.exs` | `INVENTORY_API_TOKENS` を読み(カンマ区切り→ trim → 空を除く)、`config :food_vault, FoodVaultWeb.Plugs.ServiceTokenAuth, tokens: tokens`。dev は未設定なら `["dev-inventory-api-token"]`、prod は空なら `raise`(メッセージで設定方法を示す) |
| `config/test.exs` | `config :food_vault, FoodVaultWeb.Plugs.ServiceTokenAuth, tokens: ["test-inventory-api-token", "test-inventory-api-token-2"]`(複数トークンのテスト用) |
| `lib/food_vault_web/plugs/service_token_auth.ex`(新規) | `@behaviour Plug`。`call/2`: `authorization` ヘッダ → `Bearer <token>` を取り出し → `valid_token?/1` → 不一致・欠落・形式不正は 401 で `halt`。`valid_token?/1` は public(テスト用・将来の差し替え口) |
| `lib/food_vault_web/plugs/api_format.ex`(新規) | `/api/` で始まるパスに `put_format("json")` |
| `lib/food_vault_web/endpoint.ex` | `Plug.Parsers` の前に `plug FoodVaultWeb.Plugs.ApiFormat` |
| `lib/food_vault_web/controllers/error_json.ex` | 共通形式に変更(§2) |
| `lib/food_vault/utils/operation_log.ex` | `operator/1` に `%{assigns: %{api_operator: op}}` の節を追加(`current_scope` より後ろ) |
| `docker-compose.yml` | **変更しない**。dev のデフォルトは `runtime.exs` にあり、発送側の環境変数と合わせて設定するのは段階 4 のため(requirements.md の該当記述を修正する) |

### 3.3 Web 層(`lib/food_vault_web/`)

| ファイル | 内容 |
| :-- | :-- |
| `router.ex` | 下記のルーティング。`pipeline :api` に `plug FoodVaultWeb.Plugs.ServiceTokenAuth` を追加し、雛形のコメントアウトを置き換える |
| `api/error_response.ex` | `body/3`。`%{error: code, message: message}` に `extra` をマージ |
| `api/operator.ex` | `fetch/1`(上記) |
| `api/fallback_controller.ex` | `use Phoenix.Controller, formats: [:json]`。下表の変換 |
| `api/v1/shipment_order_controller.ex` | `create` / `show` / `index` / `ship` / `cancel`。`action_fallback FoodVaultWeb.Api.FallbackController` |
| `api/v1/shipment_order_json.ex` | `show(%{order: o})`(共通のオーダー表現)、`index(%{orders: os})`(`%{shipment_orders: [...]}`) |
| `api/v1/warehouse_controller.ex` + `warehouse_json.ex` | `index` → `%{warehouses: [...]}` |
| `api/v1/item_controller.ex` + `item_json.ex` | `index`(`item_code` クエリ)→ `%{items: [...]}` |

ルーティング(`architecture §7.1` のとおり、`reverse` は含めない):

```elixir
scope "/api/v1", FoodVaultWeb.Api.V1 do
  pipe_through :api

  resources "/shipment_orders", ShipmentOrderController, only: [:create, :show, :index]
  post "/shipment_orders/:id/ship", ShipmentOrderController, :ship
  post "/shipment_orders/:id/cancel", ShipmentOrderController, :cancel
  get "/warehouses", WarehouseController, :index
  get "/items", ItemController, :index
end
```

`FallbackController` の変換:

| Context の戻り値 | 応答 |
| :-- | :-- |
| `{:error, :not_found}` | 404 `not_found`(「見つかりません。」) |
| `{:error, :invalid_state}` | 409 `invalid_state` |
| `{:error, :idempotency_conflict, order}` | 409 `idempotency_conflict`。`order` があれば `order_id`・`status`(文字列)を付加。`nil` なら付加なし |
| `{:error, :insufficient_stock, shortages}` | 422 `insufficient_stock`。`shortages`(`item_id`・`shortage_cases`・`shortage_pieces` の配列) |
| `{:error, :validation_failed, errors}` | 422 `validation_failed`。`errors`(`[%{path: [...], message: "..."}]`) |
| `{:error, :forbidden}` | 発生しない設計(actor が `{:api, _}`)。万一のとき 403 を返さず**例外にする**(クラッシュさせてログに残す)。節を作らない |

`ShipmentOrderController`:

| アクション | 動き |
| :-- | :-- |
| `create` | `Operator.fetch` → `allocate_shipment_order({:api, op}, params)` → 201(`replayed?: false`。成功時に `OperationLog`)/ 200(`replayed?: true`。ログなし) |
| `show` | `fetch_shipment_order(id)` → 200 |
| `index` | `external_slip_id` が文字列で空でない(255 文字以内)なら `list_shipment_orders_by_slip` → `render :index`。それ以外は `{:error, :validation_failed, [%{path: ["external_slip_id"], message: "を指定してください"}]}` |
| `ship` / `cancel` | `Operator.fetch`(`cancel` は `reason` も検証) → `fetch_shipment_order(id)` → `ship_shipment_order({:api, op}, order)` / `cancel_shipment_order({:api, op}, order, reason: reason)` → 200。ID 形式不正・不存在は 404 |

オーダー表現(`ShipmentOrderJSON.order/1`):

```elixir
%{
  order_id: o.id, external_slip_id: o.external_slip_id, warehouse_id: o.warehouse_id,
  shipment_date: o.shipment_date,             # Date → ISO 8601
  status: Atom.to_string(o.status), shipped_at: o.shipped_at,   # DateTime → ISO 8601(UTC)
  lines: for l <- o.lines, do: %{
    item_id: l.item_id, req_cases: l.req_cases, req_pieces: l.req_pieces,
    min_expiration_date: l.min_expiration_date,
    allocations: for a <- l.allocations, do: %{
      lot_id: a.lot_id, expiration_date: a.lot.expiration_date,
      allocated_cases: a.allocated_cases, allocated_pieces: a.allocated_pieces}}
}
```

- `expiration_date` が `9999-12-31` の「期限なし」はそのまま ISO 日付で返す(表示用の変換は発送側の責任。functional-design §7.2 の例と同じ)
- ⑥ は `id`・`warehouse_code`・`warehouse_name`、⑦ は `id`・`item_code`・`item_name`・`maker_id`・`maker_name`・`units_per_case`・`expiration_type`(文字列)

## 4. テスト

| ファイル | 内容 |
| :-- | :-- |
| `test/support/conn_case.ex` | `put_api_token/2`(`authorization: Bearer ...` を付ける)と `api_conn/0` 相当のヘルパー(JSON の `content-type`/`accept`) |
| `test/food_vault_web/plugs/service_token_auth_test.exs` | トークンなし・不正・スキーム違い・`Bearer` のみは 401、2 つ目の登録トークンも通る、設定が空なら全拒否、ヘッダ・トークンがログに出ない(`ExUnit.CaptureLog` と `normalize`)、`valid_token?/1` |
| `test/food_vault_web/plugs/api_format_test.exs` | `/api/` のみ json、他のパスは変わらない |
| `test/food_vault_web/controllers/error_json_test.exs` | 共通形式に更新 |
| `test/food_vault_web/controllers/api/v1/shipment_order_controller_test.exs` | ① 201/200/409(`order_id`・`status`)/422 不足(全明細分・DB 不変)/422 検証(`operator` 欠落・ID 形式不正・数量負・明細空・アーカイブ済み)、② ③ の成功・冪等(履歴件数が増えない)・`invalid_state`・404、発送システム起源の確定・解除が通る、`operator` の記録(受払・オーダー履歴)、⑤ `:id` の 200/404/不正 ID、`?external_slip_id=` の複数・0 件・新しい順・パラメータなし 422、壊れた JSON が JSON の 400、`reverse` ルートと存在しないルートが JSON の 404、認証なしは全エンドポイントで 401 |
| `test/food_vault_web/controllers/api/v1/warehouse_controller_test.exs` / `item_controller_test.exs` | 有効のみ・アーカイブ除外、`item_code` 絞り込み(完全一致・該当なし)、`maker_id`・`maker_name` を含む |
| `test/food_vault_web/controllers/api/v1/concurrency_test.exs` | `ConcurrencyCase` で同じ `external_slip_id` を同時に POST し、500 が無く、201 が 1 件・残りは 200(一致)、オーダーは 1 件 |
| `test/food_vault/shipment_orders_test.exs` | `fetch_shipment_order/1`(存在・不存在・形式不正)、`list_shipment_orders_by_slip/1`(新しい順・取消を含む)、`idempotency_conflict` が既存オーダーを返す |
| `test/food_vault/items_test.exs` | `search_active_items/1` |
| `test/food_vault/utils/operation_log_test.exs` | `api_operator` が操作者になる(既存テストがあれば追記) |

- 認証ヘッダは `put_req_header` で付与し、`conn` は `Phoenix.ConnTest.build_conn()` から作る(セッション・ブラウザの `log_in` は不要)
- フィクスチャは Context の公開 API 経由(`order_fixture` ほか既存のもの)

## 5. 影響範囲と更新するドキュメント

- 影響範囲: `food_vault` のみ。`food_ship` に変更は無い。Context の変更は、冪等不一致の戻り値(2 要素 → 3 要素)と参照関数の追加のみ。画面(`ShipmentOrderLive.Form`)は `external_slip_id` を渡さないため、戻り値の変更の影響を受けない。`ErrorJSON` の形式変更は API 以外に影響しない(JSON を返す画面が無い)
- 作業完了後に更新する永続ドキュメント: `functional-design.md`(§7.2 の `errors` 形式の明記、§7.4 の 409 の付加情報)、`architecture.md`(§7 の現状化: `ApiFormat`・`ErrorJSON` の扱い、§13 の環境変数、§16 #6 の「在庫 API」)、`repository-structure.md`(`api/`・`plugs/` の追加)、`development-guidelines.md`(§1.4 の段階 3 に「完了」)、`glossary.md`(サービストークン等、未収載なら追加)

## 6. 決定した未確定事項(requirements.md の「未確定」への回答)

| 項目 | 決定 |
| :-- | :-- |
| トークンの設定キー・デフォルト | `config :food_vault, FoodVaultWeb.Plugs.ServiceTokenAuth, tokens: [...]`。dev は `runtime.exs` の既定値 `dev-inventory-api-token`、test は `test.exs` の 2 つ |
| ID からの取得 | `fetch_shipment_order/1`(ULID 形式検証つき、`{:error, :not_found}`)を新設。`get_shipment_order!/1` は画面用に残す |
| `operator` の検証 | Controller 側の `Api.Operator`。`Request` には入れない(`Request` は引当の入力専用) |
| 壊れた JSON・存在しないルート | `ApiFormat` plug で `/api/` を json に固定し、`ErrorJSON` を共通形式にする |
| ⑥⑦ のページング | 付けない |
