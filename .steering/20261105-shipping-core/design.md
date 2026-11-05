# 設計: 発送側 P0(段階 4)

要求は [requirements.md](requirements.md)。対象は `food_ship` のみ。以下 `{App}` は `FoodShip`。作業単位 A〜E の順に実装し、単位ごとに品質ゲートを通してコミットする。

## 1. 現状(調査結果)

- `food_ship` はログイン・ユーザー管理のみ。業務テーブル・Context・画面・`Inventory.Client` は無い。`Permission` の業務 action は未定義で、`required_roles/0`(関数)に足す形になっている(在庫側は `@required_roles` で `authorize/2` もあるが、発送側には `authorize/2` が無い)
- 画面の構成は在庫側と同じ: `Layouts.app`、`core_components.ex`(改変禁止)、`index.ex` / `form.ex`。認可は `router.ex` の `pipe_through` ＋ `live_session on_mount` ＋ `handle_event` 先頭の `Permission.can?/2`。`UserAuth` に `:ensure_authenticated_staff` はあるが、HTTP plug の `require_authenticated_staff_user` は **発送側に未確認**(単位 A で確認し、無ければ追加する)
- Context の書き込み関数は先頭引数に `Scope` を取る(`Accounts.update_user_role(scope, ...)`)。在庫側 `Makers` も同じ。`Permission.authorize/2` の相当を発送側に追加する
- `Utils.Logger` の `:api` カテゴリは定義済み(`redact_keys` に `token`)。`OperationLog` は `create` / `update` / `delete` のみ
- 日時: 在庫側に `Utils.ConvertDatetime`(JST は +9 時間固定、tz データベース不使用)がある。発送側には無いのでコピーする(両アプリのコピーを許容: development-guidelines §4.2)
- 在庫 API(段階 3)の実際の挙動: ①は 201(再送 200)、②③は冪等(すでにその状態なら 200)、⑤は `?external_slip_id=` で `{ "shipment_orders": [...] }`(取消済みを含め新しい順)、⑦は `item_code` 省略で一覧、エラーは `{error, message, ...}`。`reason` は③で任意
- インフラ(`infra/terraform`)は `INVENTORY_API_BASE_URL`・`INVENTORY_API_TOKEN`・`INVENTORY_WAREHOUSE_ID` を Cloud Run に渡す。**`inventory_warehouse_id` は初回デプロイで空**(在庫を先に立てて ⑥ で ID を確認してから設定する運用)。このため `INVENTORY_WAREHOUSE_ID` を起動時の必須にすると初回デプロイが落ちる
- 実行環境: `docker compose` はビルドできない。段階 3 と同様に、SessionStart フックが用意した `COMPOSE_FILE="docker-compose.yml:scripts/cloud/docker-compose.cloud.yml"` で `docker compose run --rm food_ship_web mix ...` を使う(tasklist に手順を残す)

## 2. 方針

| 項目 | 決定 | 理由 |
| :-- | :-- | :-- |
| 在庫 API の呼び出し位置 | **ローカル DB のトランザクションの外**。「`pending` で保存 → API → 結果で更新」。結果の反映（伝票の更新・`slip_allocated_lots` の入れ替え）は 1 つの `Multi` ＋ `Repo.transact/1` | architecture §9.2 |
| `external_slip_id` | **伝票の `id`（ULID）** をそのまま使う。再引当・数量変更でも同じ値 | 在庫側は `cancelled` 以外の同一 ID だけを冪等判定するため、「解除 → 同じ ID で再引当」ができる（functional-design §3.1） |
| 操作者（`operator`） | `scope.user.email`。Context の書き込み関数が `scope` から取り出して `Client` に渡す。`Task` の中で `socket` は参照しない | architecture §3.2、§9.3 |
| 競合（同じ伝票の同時操作） | API を呼ぶ前に、短い `Repo.transact` で伝票を `FOR UPDATE` で読み、状態を検査する。結果の反映は **`status` と `allocation_attempted_at` が呼び出し時と同じ行にだけ** `update_all` で書き込み、0 行なら `{:error, :stale}` を返す（画面は最新を読み直す）。画面側は処理中の伝票 ID を `busy` に持って二重送信を防ぐ | 在庫側の API 呼び出しは長いため行ロックを保持しない |
| 非同期処理 | LiveView の各イベント（再引当・梱包完了・取消・登録直後の引当）は `Task.start` ＋ `handle_info`。`busy` に伝票 ID を入れて対象の行とボタンを無効化。結果メッセージは `{:slip_result, action, slip_id, result}` に統一。操作ログは `handle_info` の成功節 | architecture §9.3 |
| 外部境界のモック | `Inventory.Client` の HTTP だけ `Req.Test` のスタブで差し替える（`plug: {Req.Test, FoodShip.Inventory.Client}` を test 設定の `req_options` で渡す）。自作モジュールは mock しない | development-guidelines §5 |
| 倉庫 ID | `INVENTORY_WAREHOUSE_ID` は **任意**（空文字は未設定扱い）。未設定のとき伝票登録・再引当は `{:error, :warehouse_not_configured}` で拒否し、画面に「対象倉庫が設定されていません。管理者に連絡してください。」を表示する（`pending` にも保存しない）。`BASE_URL` と `TOKEN` は本番で必須（未設定で `raise`） | インフラの初回デプロイ順序と整合させる。architecture §11 の「必須」を「任意（未設定時は業務操作を拒否）」に修正する |
| スキーマ範囲 | 今回の migration で `clients`・`shipping_items`・`expiration_rules`・`shipping_slips`・`slip_allocated_lots` を作る。`shipping_slips` は **`reversed` を含む `status` と `reversed_*` 列・CHECK まで含める**（後から CHECK を張り替えない）。**`total_pick_id` 列は含めない**（`total_picks` テーブルと一緒に段階 5 で追加） | 段階 5 で `status` の変更が不要。FK 先が無い列は作らない |
| 用語・文言 | 発送側の画面では「出庫」を使わない（在庫側の用語）。「梱包完了」「引当解除」は内部用語で、画面は「取消」「再引当」。ラベルは `ShippingSlip.status_label/1` などに 1 か所 | glossary §8、coding-rules §16.3 |

## 3. 変更するファイル（単位別）

### 単位 A: 基盤・`Inventory.Client`

| ファイル | 内容 |
| :-- | :-- |
| `config/runtime.exs` | `config :food_ship, FoodShip.Inventory.Client` に `base_url`・`token`・`warehouse_id`・`connect_timeout`・`receive_timeout`。dev の既定: `base_url=http://food_vault_web:4000`、`token=dev-inventory-api-token`（在庫側 dev の既定と同じ）。本番は `INVENTORY_API_BASE_URL`・`INVENTORY_API_TOKEN` が未設定なら `raise`。`warehouse_id` は空なら `nil` |
| `config/test.exs` | `base_url`・`token`・`warehouse_id`（テスト用の固定 ULID）、`retry_base_ms: 0`、`req_options: [plug: {Req.Test, FoodShip.Inventory.Client}]` |
| `lib/food_ship/inventory/client.ex` | 外部境界。下記 §6。`config/1` 相当の private 関数は `Application.get_env(:food_ship, __MODULE__)` を実行時に読む |
| `lib/food_ship/utils/convert_datetime.ex` | 在庫側のコピー。JST 変換（`today_jst/0`・`format_jst/1`） |
| `lib/food_ship/utils/calc.ex` | 純粋関数: `total_piece_qty(order_count, pieces_per_order)`、`default_box_count(order_count, boxes_per_order)`、`min_expiration_date(ship_date, min_remaining_days \| nil)` |
| `lib/food_ship/utils/permission.ex` | action を追加（§8）。`authorize/2`（`:ok` / `{:error, :forbidden}`）を追加 |
| `docker-compose.yml` | `food_ship_web` の `environment` に `INVENTORY_API_BASE_URL: http://food_vault_web:4000`、`INVENTORY_API_TOKEN: ${INVENTORY_API_TOKEN-dev-inventory-api-token}`、`INVENTORY_WAREHOUSE_ID: ${INVENTORY_WAREHOUSE_ID-}` |
| `food_ship/README.md` | 開発時の倉庫 ID の設定手順（在庫側 `GET /api/v1/warehouses` で ID を確認して `INVENTORY_WAREHOUSE_ID` に設定） |
| `test/support/` | `inventory_stub.ex`（`Req.Test` のスタブ定義ヘルパー: 引当成功・在庫不足・各エラー・照会・解除・確定）、`ConnCase`/`DataCase` の変更は最小限 |

### 単位 B: マスタ（F-S1）

| ファイル | 内容 |
| :-- | :-- |
| `priv/repo/migrations/…_create_clients_shipping_items_expiration_rules.exs` | `clients`・`shipping_items`・`expiration_rules`（functional-design §3.2）。`expiration_rules` に `UNIQUE (client_id, shipping_item_id)` と FK 索引 |
| `lib/food_ship/clients.ex` + `clients/client.ex` | `Client` スキーマ（`FoodShip.Clients.Client`。`Inventory.Client` と紛らわしいため、モジュール名は **`FoodShip.Clients.Client`**、画面の語は「発注元」）。`list_clients/1`（ページング）、`all_clients/0`（有効のみ・選択肢）、`get_client!/1`、`change_client/2`、`create_client/2`、`update_client/3`、`archive_client/2`、`restore_client/2` |
| `lib/food_ship/shipping_items.ex` + `shipping_items/shipping_item.ex` | `ShippingItem`。`list_shipping_items/1`、`all_shipping_items/0`（有効のみ）、`get_shipping_item!/1`、`change_shipping_item/2`、`create_shipping_item/2`、`update_shipping_item/3`、`archive_*` / `restore_*`、`fetch_inventory_item/1`（商品コードから `Client.find_item/1` → 初期入力用の属性マップ）、`refresh_from_inventory/2`（`inventory_item_id` で在庫側を引き直して `item_code`・`item_name`・`inventory_maker_id`・`maker_name` を更新） |
| `lib/food_ship/expiration_rules.ex` + `expiration_rules/expiration_rule.ex` | `list_expiration_rules/1`（発注元・商品を preload）、`get_expiration_rule!/1`、`get_rule(client_id, shipping_item_id)`、`change_*`、`create_*`、`update_*`、`delete_expiration_rule/2`（物理削除） |
| `lib/food_ship_web/live/client_live/index.ex`、`shipping_item_live/index.ex`、`expiration_rule_live/index.ex` | 参照一覧（全ロール）。`/masters/clients` など。`admin` には編集リンクと「再取得」ボタンを表示する |
| `lib/food_ship_web/live/management/{client,shipping_item,expiration_rule}_live/form.ex` | 登録・編集（`admin`）。`/management/clients/new` など。発送商品フォームは「商品コードで取得」ボタン（`Task`）で在庫側の値を初期入力する |
| `router.ex` | 上記ルート。権限は §8 |

- 発送商品の `item_code` は在庫側と同じ値（取得時点のコピー）。変更時は一意制約違反を changeset エラーにする。`inventory_item_id` の変更は不可（編集では読み取り専用。取得し直す場合は `refresh_from_inventory/2`）
- 出荷期限ルールのフォームは、アーカイブ済みの発注元・商品を選択肢に出さない
- `unique_constraint` と `unsafe_validate_unique` は対で書く。`client_code`・`item_code`・`inventory_item_id`・`(client_id, shipping_item_id)` はいずれも `unique_index` を作る

### 単位 C: 伝票登録・引当・再引当（F-S2）

| ファイル | 内容 |
| :-- | :-- |
| `priv/repo/migrations/…_create_shipping_slips.exs` | `shipping_slips`・`slip_allocated_lots`・シーケンス（§4） |
| `lib/food_ship/shipping_slips.ex` | 公開 API（§5）。`ShippingSlip`・`SlipAllocatedLot` を扱う |
| `lib/food_ship/shipping_slips/shipping_slip.ex` | スキーマ。changeset は用途別（§4） |
| `lib/food_ship/shipping_slips/slip_allocated_lot.ex` | スキーマ |
| `lib/food_ship/shipping_slips/allocation_result.ex` | 純粋関数。在庫 API の応答（`Client` の戻り値）→ 伝票に反映する値の決定（§5.2）。単体テストしやすいよう Context から分離する |
| `lib/food_ship_web/live/shipping_slip_live/form.ex` | 登録（`:new`）・数量変更（`:edit`）。リアルタイム計算、保存、`Task` での引当 |
| `router.ex` | `/shipping_slips/new`・`/shipping_slips/:id/edit`（staff 以上） |

### 単位 D: 作業画面・数量変更・取消（F-S3）

| ファイル | 内容 |
| :-- | :-- |
| `lib/food_ship_web/live/shipping_slip_live/index.ex` | 作業画面（`/shipping_slips`）。タブ・フィルタ・伝票行・再引当・取消・数量変更へのリンク。`busy` と `Task` |
| `lib/food_ship_web/live/shipping_slip_live/components.ex` | 状態バッジ・引当ロット表示・エラー表示のコンポーネント（`core_components.ex` は改変しない） |
| `lib/food_ship/shipping_slips.ex` | `cancel_shipping_slip/2`、`list_shipping_slips/2`、`summarize_ship_dates/1` |
| `lib/food_ship_web/components/layouts.ex` | ナビに「作業画面」「伝票登録」「マスタ」を追加（`Permission.can?/2` で表示を絞るが、表示は補助で認可の本体は 3 層） |
| `lib/food_ship_web/controllers/page_controller.ex` ほか | `/` は作業画面へ `redirect`（ホームのテンプレートは不要になれば削除） |

### 単位 E: 梱包完了（F-S4）

| ファイル | 内容 |
| :-- | :-- |
| `lib/food_ship/shipping_slips.ex` | `pack_shipping_slip/2`、`update_box_count/3` |
| `lib/food_ship_web/live/shipping_slip_live/index.ex` | 「梱包完了」ボタン（`data-confirm`）、箱数のインライン編集、グレーアウト |
| ドキュメント | 永続ドキュメントの更新（§10） |

## 4. データモデル（migration）

### `shipping_slips`

functional-design §3.2 のとおり。今回の差分だけ書く。

- `total_pick_id` は含めない（段階 5）。`slip_no` は `CREATE SEQUENCE shipping_slips_slip_no_seq` ＋ 列の `DEFAULT nextval(...)`（`execute(up, down)` の 2 引数形式）。スキーマでは `field :slip_no, :integer, read_after_writes: true` とし、`cast` に含めない（読み取り専用）
- `slip_no` の表示は `S-000123`（`ShippingSlip.slip_no_label/1`）
- 部分ユニーク `UNIQUE (client_id, client_slip_no, shipping_item_id) WHERE client_slip_no IS NOT NULL AND status NOT IN ('cancelled', 'reversed')`。`unique_constraint` の `name` を明示して「すでに登録されています。」にする
- CHECK は §3.2 の列挙どおり（`allocated` / `packed` / `reversed` なら `inventory_order_id` NOT NULL、`packed` / `cancelled` / `reversed` の必須列、`shortage` 以外は `shortage_pieces IS NULL`、`order_count > 0` ほか）。changeset 側にも同じ検証を置く
- 索引: `(scheduled_ship_date, status)` / `(client_id)` / `(shipping_item_id)` / `(inventory_order_id)` / `(status, allocation_attempted_at)` / 各 `*_by_user_id`。`create index` は `create table` の外
- `status` / `allocation_error` / `input_source` は `Ecto.Enum`（DB は string）。`input_source` は今回 `manual` のみ使うが列挙には `csv` も含める

### `slip_allocated_lots`

`UNIQUE (shipping_slip_id, inventory_lot_id)`、`allocated_pieces > 0` の CHECK、FK 索引。表示用キャッシュで、在庫の正は在庫側。再引当・解除・取消で同一トランザクション内に旧行を削除する。

## 5. `ShippingSlips` Context

書き込み関数は先頭に `scope` を取り、`Permission.authorize/2` で二重に検査する（Web 層と二重化）。戻り値は `{:ok, slip}` / `{:error, changeset}` / `{:error, atom}` の契約（coding-rules §4.3）。

### 5.1 公開関数

| 関数 | 内容 |
| :-- | :-- |
| `list_shipping_slips(date, filter)` | 出荷予定日の伝票（`slip_no` 昇順）。`filter`: `:all` / `:unpacked`（`pending`・`allocated`・`shortage`）/ `:shortage`。`client`・`shipping_item`・`allocated_lots`（期限日昇順）を preload |
| `summarize_ship_dates(from_date)` | `from_date` 以降の出荷予定日ごとの `%{date, remaining}`（残件数 = `pending`・`allocated`・`shortage`）。伝票が 1 件でもある日付のみ |
| `get_shipping_slip!/1` | 取得（preload 付き） |
| `change_shipping_slip(slip, attrs)` | フォーム用の changeset（箱数・計算値のプレビューに使う） |
| `preview(client_id, shipping_item_id, ship_date, order_count)` | 画面のリアルタイム表示用。`%{total_piece_qty, default_box_count, min_expiration_date, rule_days}`。DB は読むが書かない |
| `create_shipping_slip(scope, attrs)` | 発注元・商品・出荷予定日・件数・任意の発注元伝票番号・（手修正した）箱数を受け、**マスタ（`boxes_per_order`・`pieces_per_order`・ルール）から計算して `pending` で保存**する。発注元・商品がアーカイブ済みなら changeset エラー。倉庫未設定なら `{:error, :warehouse_not_configured}`（保存しない）。`created_by_user_id` を記録 |
| `allocate_shipping_slip(scope, slip)` | 引当・再引当（§5.2）。`pending` / `shortage` のみ。戻り値は `{:ok, slip}`（結果が `allocated` / `shortage` / `pending(allocation_error)` / 突合で `packed`）、`{:error, :invalid_status}`、`{:error, :stale}`、`{:error, :warehouse_not_configured}`、`{:error, :forbidden}` |
| `update_shipping_slip(scope, slip, attrs)` | 件数・出荷予定日の変更（`pending` / `allocated` / `shortage` のみ）。`box_count`・`total_piece_qty`・`min_expiration_date` を再計算し `pending` に戻す（`shortage_pieces`・`allocation_error` は NULL。**`inventory_order_id` と `slip_allocated_lots` は旧引当の解除まで残す**）。この後に呼び出し側が `allocate_shipping_slip/2` を実行する |
| `cancel_shipping_slip(scope, slip)` | 梱包前の取消（§5.3） |
| `pack_shipping_slip(scope, slip)` | 梱包完了（§5.4） |
| `update_box_count(scope, slip, box_count)` | `box_count >= 1` の整数。`packed` / `cancelled` / `reversed` 以外で可（在庫に影響しない）。梱包時の修正は `packed` にする前でも後でもなく**未梱包の間のみ** |

### 5.2 引当・再引当の手順（`allocate_shipping_slip/2`）

functional-design §6.2・§6.3 に従う。

1. **準備（トランザクション内）**: 伝票を `FOR UPDATE` で読み、`pending` / `shortage` か検査。最低許容期限日を現在のルールで再計算し、`allocation_attempted_at = now`・`allocation_error = nil` で保存して**コミット**（以降は API 呼び出し）
2. **旧オーダーの解除**（`slip.allocation_attempted_at` が保存前に非 NULL だった = 過去に API を呼んだ可能性がある場合のみ）:
   - `Client.list_orders_by_slip(slip.id)`（⑤）で取消済みを除く全オーダーを取得。`allocated` のオーダーそれぞれに `Client.cancel_order/3`（③。`reason` は「再引当のため」）
   - 全オーダーが解除できたら、**1 つのトランザクション**で `inventory_order_id = nil`・`slip_allocated_lots` 削除（`shortage` の伝票は元々どちらも無いので何もしない）
   - 照会・解除が失敗（接続など）したら `pending` ＋ `allocation_error` に反映して返す（次の再引当で手順 2 からやり直す）
   - 在庫側が `shipped` のオーダーがあれば、再引当せず、突合して `packed`（`packed_by_user_id` = 操作者、`packed_at` = 在庫の `shipped_at`）に更新して返す
3. **引当**: `Client.allocate/1`（①）。`external_slip_id = slip.id`、`shipment_date = scheduled_ship_date`、`warehouse_id`（設定値）、`operator`、明細 1 行（`item_id = inventory_item_id`、`req_cases = 0`、`req_pieces = total_piece_qty`、`min_expiration_date`）
4. **結果の適用**（`AllocationResult`、1 つの `Multi` ＋ `Repo.transact/1`）:

| `Client` の戻り値 | 伝票の更新 |
| :-- | :-- |
| `{:ok, order, _}` かつ 全明細の `allocated_pieces` 合計 = `total_piece_qty`（`allocated_cases` は全て 0） | `allocated`、`inventory_order_id = order.order_id`、`shortage_pieces`・`allocation_error` = NULL、`slip_allocated_lots` を（旧行削除 → ロット別に `allocated_pieces` と `expiration_date` を挿入） |
| `{:ok, order, _}` だが合計が不一致 | `pending`、`allocation_error = validation_failed`、`inventory_order_id = order.order_id`（次の再引当で解除できるよう保存）、ロットは保存しない |
| `{:error, :insufficient_stock, shortages}` | `shortage`、`shortage_pieces` = 不足バラ数の合計（`shortages` の `shortage_pieces` ＋ `shortage_cases × units_per_case` は **発送側は `req_cases = 0` のため `shortage_pieces` のみ**） |
| `{:error, :validation_failed, errors}` | `pending`、`validation_failed`。`errors` は返り値で呼び出し側に渡し、画面に表示する（DB には保存しない） |
| `{:error, :not_found}` | `pending`、`not_found` |
| `{:error, :idempotency_conflict, info}` | `pending`、`idempotency_conflict`、`inventory_order_id = info.order_id`（あれば） |
| `{:error, :unauthorized}` | `pending`、`unauthorized` |
| `{:error, :connection}`（リトライ後も失敗）・想定外の応答 | `pending`、`connection` |

- 結果の書き込みは `status` と `allocation_attempted_at` が手順 1 の値のままの行にだけ `update_all` で適用し、0 行なら `{:error, :stale}`
- `{:ok, slip}` の `slip` には、画面に出す補足（`validation_failed` の `errors`）を `slip.__meta__` ではなく**戻り値の第 3 要素**で返す: `{:ok, slip, %{errors: [...]}}`。`errors` が無い場合は `{:ok, slip}`

### 5.3 取消（`cancel_shipping_slip/2`）

`pending` / `shortage` / `allocated` のみ。`allocation_attempted_at` が非 NULL（API を呼んだ可能性がある）または `inventory_order_id` があれば、§5.2 の手順 2 と同じく ⑤ → `allocated` を ③ で解除する。在庫側が `shipped` なら `{:error, {:remote_state, :shipped}}`（取消できない。梱包完了の突合を促す）。解除が失敗したら `{:error, :connection}` などで**ローカルは変更しない**（`cancelled` にしない。再度取消できる）。解除が済んだら 1 トランザクションで `cancelled`・`cancelled_at`・`cancelled_by_user_id`・`inventory_order_id = nil`・`slip_allocated_lots` 削除。

### 5.4 梱包完了（`pack_shipping_slip/2`）

`allocated` のみ。`Client.ship_order(order_id, operator)`（②）。

| 結果 | 動作 |
| :-- | :-- |
| 成功 | `packed`・`packed_at`・`packed_by_user_id`（`inventory_order_id` は残す） |
| `{:error, :invalid_state}` | `Client.get_order/1`（⑤）。在庫側が `shipped` なら `packed` に更新して `{:ok, slip}`。それ以外は `{:error, {:remote_state, status}}` |
| `{:error, :connection}` | `allocated` のまま `{:error, :connection}`（再試行は画面から） |
| `{:error, :not_found}` / `:unauthorized` | `allocated` のまま同じエラー |

## 6. `FoodShip.Inventory.Client`

- `Req.new(base_url:, auth: {:bearer, token}, connect_options: [timeout: connect], receive_timeout:, retry: :transient, max_retries: 3, retry_delay: fn n -> base * 2 ** n end, retry_log_level: false)` を `new/0` で組み、`req_options`（test のスタブ）を最後にマージする。リトライは接続エラー・タイムアウト・408/429/500/502/503/504（Req の `:transient` の既定）で、401/404/409/422 は再試行しない
- 関数と戻り値（タグ付きタプル）:

| 関数 | API | 成功 |
| :-- | :-- | :-- |
| `allocate(params)` | ① `POST /api/v1/shipment_orders` | `{:ok, order, :created \| :replayed}` |
| `ship_order(order_id, operator)` | ② | `{:ok, order}` |
| `cancel_order(order_id, operator, reason \\ nil)` | ③ | `{:ok, order}` |
| `get_order(order_id)` | ⑤ `:id` | `{:ok, order}` |
| `list_orders_by_slip(external_slip_id)` | ⑤ `?external_slip_id=` | `{:ok, [order]}`（新しい順） |
| `find_item(item_code)` | ⑦ `?item_code=` | `{:ok, item}`（完全一致）／`{:error, :not_found}` |

- 共通のエラー: `{:error, :unauthorized}`、`{:error, :not_found}`、`{:error, :invalid_state}`、`{:error, :idempotency_conflict, %{order_id:, status:}}`、`{:error, :insufficient_stock, [%{item_id:, shortage_cases:, shortage_pieces:}]}`、`{:error, :validation_failed, [%{path:, message:}]}`、`{:error, :connection}`（トランスポートエラー・リトライ後の 5xx・想定外のステータス／本文）
- 応答の変換: オーダーは `%{order_id, external_slip_id, warehouse_id, shipment_date: Date, status: atom, shipped_at: DateTime \| nil, lines: [%{item_id, req_cases, req_pieces, min_expiration_date: Date \| nil, allocations: [%{lot_id, expiration_date: Date, allocated_cases, allocated_pieces}]}]}`。`status` は固定の対応表で atom にし、`String.to_atom` は使わない。日付は `Date.from_iso8601/1`
- ログ: 呼び出しごとに `Logger.info(..., :api, %{method, path, status})`。トークンと `Authorization` ヘッダは出さない（`redact_keys` に `token` あり）。失敗は `warning`
- `warehouse_id/0`: 設定値（空は `nil`）。`nil` のときの拒否は Context（`ShippingSlips`）が行う
- 5xx など想定外の応答の本文は保持せず、`:connection` とだけ扱う（ログには status のみ）

## 7. 画面

### 7.1 ルーティング

| パス | LiveView | 必要ロール |
| :-- | :-- | :-- |
| `/` | `PageController` が `/shipping_slips` へ redirect | 全ロール |
| `/shipping_slips` | `ShippingSlipLive.Index`（作業画面。`?date=YYYY-MM-DD&filter=all\|unpacked\|shortage`） | 全ロール |
| `/shipping_slips/new` | `ShippingSlipLive.Form` `:new` | staff 以上 |
| `/shipping_slips/:id/edit` | `ShippingSlipLive.Form` `:edit` | staff 以上 |
| `/masters/clients`、`/masters/shipping_items`、`/masters/expiration_rules` | 各 `Index` | 全ロール（参照） |
| `/management/clients/new`・`/:id/edit` ほか（3 マスタ） | 各 `Form` | admin |

`live_session` は在庫側と同じ 3 つ（全ロール `:ensure_authenticated`・staff 以上 `:ensure_authenticated_staff`・admin `:ensure_authenticated_admin`）。不正な ID は `get_shipping_slip!` が `Ecto.NoResultsError`（404）になる。

### 7.2 伝票登録・変更フォーム（`ShippingSlipLive.Form`）

- 入力: 発注元（有効のみ）・出荷予定日・商品（有効のみ）・件数・発注元伝票番号（任意）・箱数
- `phx-change="validate"` で `preview/4` を呼び、**箱数（初期値 = 件数 × 標準箱数）・出庫総数量（バラ。読み取り専用表示）・最低許容期限日（ルールがあれば）** を表示する。箱数は手修正でき、手修正後は件数を変えても上書きしない（`_target` が `box_count` のとき `box_count_touched` を立てる）。バラ数は入力欄にしない
- 保存（`save`）: `Permission.can?(:manage_shipping_slips)` を検査 → `create_shipping_slip/2` が成功したら `assign(:allocating, true)` で入力を無効化し、`Task.start` で `allocate_shipping_slip/2` を実行。`handle_info({:slip_result, :allocate, id, result})` で、`allocated` は「引き当てました。」、`shortage` は「在庫が不足しています（不足 N 個）。」、`pending` は一時／恒久で文言を分けて表示し、作業画面（その伝票の出荷予定日タブ）に `push_navigate`。通信失敗でも入力内容は `pending` として保存されている
- 変更（`:edit`）: 確認ダイアログ付きの「変更する」。ダイアログには「在庫不足の場合、現在の引当は解除されます」（`allocated` の伝票のみ）を表示。`update_shipping_slip/3` → `Task` で `allocate_shipping_slip/2`
- 二重登録: `client_slip_no` の部分ユニーク違反は changeset エラー「すでに登録されています。」
- 倉庫未設定のときは画面上部に警告を出し、保存を拒否する

### 7.3 作業画面（`ShippingSlipLive.Index`）

- タブ: `summarize_ship_dates/1`（今日の JST の 7 日前から）。各タブ「11/15 (残3件)」。`?date=` が無ければ今日以降で最も近い日、無ければ今日。`?date=` が範囲外でも表示できる
- フィルタ: 「すべて」「未梱包のみ」「在庫不足のみ」（未ピックのみは段階 5）
- 伝票行: 伝票番号（`S-xxxxxx`）、発注元、商品、件数、箱数（インライン編集）、バラ数、状態バッジ、引当ロット（期限日 × 個数、期限なしは「期限なし」）、`pending` の行は引当エラー（一時／恒久の文言）＋最終試行日時（JST）。梱包済みはグレーアウト。梱包完了後に登録された未梱包の伝票は、同じタブで行をハイライト（タブ内に `packed` が 1 件でもあり、かつ未梱包の伝票を強調）
- 行の操作（`staff` 以上のみ表示。**イベントでも `Permission.can?/2`**）: 再引当（`pending` / `shortage`）、梱包完了（`allocated`、`data-confirm`）、数量変更（リンク → Form `:edit`）、取消（`data-confirm`）、箱数更新
- イベント名は `reallocate` / `pack` / `cancel` / `update_box_count`（`phx-value-id`）。処理中は `busy` の伝票の行・ボタンを `disabled`。結果は `handle_info({:slip_result, action, id, result})` で伝票 1 行を読み直し（`stream_insert` ではなく、件数が少ないので一覧を再取得して assign）、成功時のみ `OperationLog`、失敗時は §9 のメッセージ
- 在庫 API 停止中の梱包完了は「在庫システムに接続できませんでした。時間をおいて、もう一度梱包完了を行ってください。」を表示

## 8. 認可

`Permission` に追加（権限表 §9.3 の発送システムと 1 対 1）:

| action | 最低ロール | 対応する操作 |
| :-- | :-- | :-- |
| `manage_masters` | `admin` | 発注元・発送商品・出荷期限ルールの編集・アーカイブ・再取得 |
| `manage_shipping_slips` | `staff` | 伝票登録・再引当・数量変更・取消 |
| `pack_shipping_slips` | `staff` | 箱数の修正・梱包完了 |

- 3 層: ① `router.ex` の `pipe_through`（admin / staff / 全ロール）、② `live_session` の `on_mount`、③ `handle_event` 先頭の `Permission.can?/2`（不許可は `put_flash(:error, "権限がありません。")`）。Context の書き込み関数も `authorize/2` で `{:error, :forbidden}`
- 参照一覧（全ロール）の画面に編集ボタン・操作ボタンを置くが、`Permission.can?/2` で表示を絞るのは補助。イベント側の検査が本体

## 9. 文言（案）

| 場面 | 文言 |
| :-- | :-- |
| 一時エラー（`connection`） | 通信に失敗しました。再引当を押してください。 |
| 恒久エラー | 再試行しても直りません。設定またはマスタを確認してください（原因: …） |
| 在庫不足 | 在庫が不足しています（不足 N 個）。入荷後に再引当してください。 |
| 二重登録 | すでに登録されています。 |
| 倉庫未設定 | 対象倉庫が設定されていません。管理者に連絡してください。 |
| 引当合計の不一致 | 在庫側の引当数が一致しません。再引当してください。 |
| 競合 | 他の操作で更新されました。画面を読み込み直します。 |
| 梱包完了の確認 | 梱包完了にします。在庫が減算され、元に戻せません。よろしいですか？ |

用語集（glossary）に「引当エラー」「再引当」「梱包完了」がある場合はそれに揃える。実装時に確認し、足りなければ glossary に追加する。

## 10. テスト

| 対象 | 内容 |
| :-- | :-- |
| `Utils.Calc` / `ConvertDatetime` | 計算・JST 変換（`async: true`） |
| `Inventory.Client` | `Req.Test` で ①②③⑤⑦ の成功・201/200・401/404/409/422・5xx のリトライ（3 回で失敗→`:connection`、途中で成功）・4xx の非リトライ・接続エラー・不正な本文。リクエストに `Authorization`・`operator` が付くこと。トークンがログに出ないこと |
| `AllocationResult` | 応答 → 反映値の対応表（合計一致・不一致・不足・各エラー）を純粋関数でテスト |
| マスタ Context | CRUD、アーカイブ・復帰、一意制約、権限（admin 以外は `{:error, :forbidden}`）、`fetch_inventory_item`・`refresh_from_inventory`（スタブ） |
| `ShippingSlips` | `create_shipping_slip`（計算値・`pending`・二重登録・アーカイブ済み・倉庫未設定）、`allocate_shipping_slip`（`allocated` + ロット保存、`shortage`、各エラーの `allocation_error`、合計不一致、**再引当で既存オーダーを照会・解除してから引当**、在庫側 `shipped` の突合、解除失敗で `pending` のまま、`stale`）、`update_shipping_slip`（`pending` へ戻る・旧引当を残す）、`cancel_shipping_slip`（各状態、解除失敗でローカルが変わらない）、`pack_shipping_slip`（成功・409 → 照会で `shipped` なら `packed`・停止時に `allocated` のまま・復旧後の再実行）、`update_box_count`。失敗時の DB 状態（ロールバック）を検証 |
| 並行性 | 同じ伝票の再引当を 2 プロセスで同時に走らせ、片方が `{:error, :stale}` になりデータが壊れないこと（`ConcurrencyCase`は発送側に無いため、同じ作りを発送側にコピーして使う。`sandbox: false`・`TRUNCATE` で後始末） |
| LiveView | 作業画面（タブ・残件数・フィルタ・ロット表示・`pending` のエラー表示・ハイライト・グレーアウト）、登録フォーム（リアルタイム計算・箱数の手修正・保存して引当結果の表示・二重登録）、数量変更の確認、取消、梱包完了、再引当。いずれも画面の表示と DB の書き込みの両方を検証。`Task` を使うイベントは `Req.Test` を共有モードにし、結果を `render` で確認 |
| 認可 | `viewer` は操作ボタンが無く、イベントを直接送っても拒否。`staff` は伝票操作可・マスタ編集不可。`admin` はマスタ編集可。未ログインはログイン画面へ |
| 例外ケース | functional-design §6.11 の ①②⑤⑦⑧ を上のテストで確認（在庫不足の保存／通信失敗の `pending` と再引当での復旧／二重登録／在庫側マスタとの不整合（404・422 の恒久エラー）／在庫停止中の梱包） |

- 実行は `docker compose run --rm food_ship_web mix test`。`Req.Test` を `Task` から使うため、LiveView・Context のテストは `async: false`（共有モード）。`food_vault` のテストは変更しないが、最後に両アプリで品質ゲートを通す

## 11. 永続ドキュメントの更新（承認を得て行う）

| ドキュメント | 内容 |
| :-- | :-- |
| `functional-design.md` | §6 の画面・操作で実装と差が出た点（箱数の手修正・倉庫未設定の扱い・ルーティング）。§8.2 のルーティング |
| `architecture.md` | §9 を現状化（`Client` の戻り値、`busy` と `Task` の構成）、§11 の `INVENTORY_WAREHOUSE_ID` を任意（未設定時は業務操作を拒否）に変更、§16 #6 の「発送側の `INVENTORY_API_*`」を解決済みに |
| `repository-structure.md` | 発送側のディレクトリ（`inventory/`・各 Context・LiveView）の追加 |
| `development-guidelines.md` | §1.4 の段階 4 を「完了」に |
| `glossary.md` | 「引当エラー」「再引当」「梱包完了」ほか、未収載の用語 |
| `.steering/20261105-gcp-terraform` | `inventory_warehouse_id` の運用手順（空のまま起動でき、設定するまで業務操作が拒否される）を README に追記 |

## 12. 未確定・リスク

- **`Req.Test` と `Task` の併用**: スタブの所有者を `Task` に渡すため共有モード（`async: false`）を前提にした。うまくいかなければ `Req.Test.allow/3` を使う（実装時に確認）
- **`req_options` の置き場所**: test 設定の `plug: {Req.Test, ...}` を `config/test.exs` に書く（コンパイル時 config に秘密情報は無いため問題ない）。本番設定には `req_options` を置かない
- **`shipped` の突合で `packed` にする操作者**: 本来の梱包者は不明なため、操作した `staff` を `packed_by_user_id` にする。画面に「在庫側の出庫済みに合わせて更新しました。」と表示する
- **作業画面の再取得**: 件数が少ない前提で一覧を再取得する。伝票が多くなったらページング・`stream` を検討（P1 以降）
- **リトライ待機のテスト**: `retry_base_ms: 0` でテストを速くする。本番は 1000（1・2・4 秒）
- 引当エラーの `validation_failed` の `errors` は DB に保存しない（画面の初回表示のみ）。再読み込み後は「原因: 入力が正しくありません」程度の表示になる。保存が必要なら `shipping_slips` に列を足す（今回は見送り）
