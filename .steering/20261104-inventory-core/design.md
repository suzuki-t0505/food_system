# 設計: 在庫側の核(段階 2)

要求は [requirements.md](requirements.md)。対象は `food_vault` のみ。以下 `{App}` は `FoodVault`。作業単位 A〜E の順に実装し、単位ごとに `make check` を通してコミットする。

## 1. 現状(調査結果)

- 業務テーブル・業務 Context・業務画面は 0 件。`users` 系のマイグレーション 1 本のみ
- `FoodVault.Schema`(ULID 主キー・外部キー)、`Utils.Permission`(`change_own_password`・`manage_users`・`emergency_ship_order`)、`Utils.OperationLog`、`Accounts`(先頭引数に `Scope`、`Permission.can?/2` を二重に検査する)がある。`Utils.Calc` は無い
- ルーターは「認証系 / パスワード変更 / 全ロール(`get "/"` のみ) / `/management`(admin の `live_session`)」。**`staff` 用の `live_session` と全ロール用の `live_session` はまだ無い**。`UserAuth` の on_mount `:ensure_authenticated` / `:ensure_authenticated_staff` / `:ensure_authenticated_admin` は実装済み
- `Layouts.app` はヘッダーのみで業務ナビゲーションが無い。`/` のホームは最小の画面
- `Repo` に Scrivener が無い(coding-rules §6.5 は `Repo` に `use Scrivener` を前提にしている)
- テスト基盤: `DataCase`・`ConnCase`(`register_and_log_in_user` はロール指定可)・`accounts_fixtures.ex`。`async` は既定 false
- 参考: 実装済みの `UserLive.Index` は `handle_event` 先頭で `Permission.can?/2` を検査し、成功時に `OperationLog.info` を呼ぶ形。同じ型に揃える

## 2. 方針

| 項目 | 決定 | 理由 |
| :-- | :-- | :-- |
| Context の分割 | `Makers`・`Warehouses`・`Items`・`Inventories`(ロット・受払履歴)・`ShipmentOrders`(引当・確定・解除)・`Utils.Calc`(純関数)。architecture §3.2 のとおり | 既存の設計に従う |
| ロックと更新の置き場 | ロットのロック・加減算・受払履歴の記録は **`Inventories` に 1 か所**。`ShipmentOrders` は同一 Multi から呼ぶ(architecture §3.3) | ロックキー順・CHECK に合う更新が分散しない |
| 操作者(actor) | 書き込み関数の第 1 引数。`%User{}`(画面)または `{:api, operator}`(段階 3 の API)。`user_id` / `operator` のどちらかを記録 | architecture §3.2。段階 3 でそのまま使える |
| 権限検査 | `%User{}` の actor は Context 内でも `Permission.can?/2`(不許可は `{:error, :forbidden}`)。`{:api, _}` は検査しない(サービストークンで認証済み。ロール判定は呼び出し側の責任) | 二重化。functional-design §9.3 |
| マスタの操作 | `Makers`・`Warehouses`・`Items` の書き込みは `Scope` を第 1 引数(`Accounts` と同じ)。操作者は記録しない(テーブルに列が無い) | マスタに操作者の記録要件が無い |
| 戻り値 | 単純な CRUD は `{:ok, struct} \| {:error, changeset}`。Multi 系は `{:ok, %{step => value}}`。業務エラーは atom: `:forbidden`・`:invalid_state`・`:not_found`・`:idempotency_conflict`・`:archived`・`{:error, :insufficient_stock, shortages}`(architecture §6.1) | coding-rules §4.3 |
| 引当の 2 段構成 | ① ロック済みロットから**純粋関数で引当計画**を作る(`ShipmentOrders.AllocationPlan`)→ ② 計画を Multi で適用 | architecture §6.1。テストしやすい |
| ページング | `scrivener_ecto` を追加し、`Repo` に `use Scrivener, page_size: 20`。`list_*` は文字列キー params を `Repo.paginate/1` へ渡す | coding-rules §6.5。取得できない環境の場合は `Repo.paginate` 相当を `Utils` に自作して置き換える(戻り値の形は同じ) |
| 日付 | 期限日・入荷日・出庫予定日は `date`。入荷日の既定は**今日(JST)**。表示直前のみ JST 変換が必要なのは `utc_datetime` のみ | functional-design §2 |
| 期限なし | `Inventories` が `9999-12-31` を設定。表示は `Calc.expiration_label/1`(「期限なし」) | §5.2、§3.1 |
| 受払履歴の追記専用 | `InventoryTransaction` に更新・削除の関数を作らない。changeset は `insert` 用のみ。DB 側でも `inventory_transactions` / `shipment_order_events` の UPDATE・DELETE を拒否するトリガーを設置 | F-V6 の「更新・削除できない」を DB で担保 |
| `external_slip_id` の冪等 | Context で実装(architecture §6.3)。正規化(`warehouse_id`・`shipment_date`・明細を `item_id` 順の `item_id`/`req_cases`/`req_pieces`/`min_expiration_date`)の比較。部分ユニーク違反は既存を再取得して再比較 | API は段階 3 だが、競合時の挙動はここで固める |
| 画面登録の `external_slip_id` | 画面登録のオーダーは常に `NULL`。`NULL` でないものを「発送システム起源」とみなす | functional-design §8.1 |
| 発送システム起源の確定・解除 | 画面経由(`%User{}` actor)では `{:error, :forbidden}`。`{:api, _}` actor は許可 | F-V8 は P1。API は段階 3 で使う |
| 入力の検証 | 引当の入力は Context で検証し、`{:error, changeset}` ではなく `{:error, :validation_failed, errors}`(`errors` は `[%{path: [...], message: "..."}]`)を返す。画面は `errors` をフォーム下に表示 | `cast_assoc` を使わない(coding-rules §5.8)ため、明細の可変個入力は changeset にできない |

## 3. 変更するファイル

### 3.1 依存・設定

- `mix.exs`: `{:scrivener_ecto, "~> 3.1"}` を追加。`lib/food_vault/repo.ex` に `use Scrivener, page_size: 20`
- `lib/food_vault/utils/permission.ex`: action を追加

| action | 最低ロール | 用途 |
| :-- | :-- | :-- |
| `manage_masters` | `admin` | メーカー・倉庫・商品の編集・アーカイブ・復帰 |
| `receive_inventory` | `staff` | 入荷登録 |
| `manage_shipment_order` | `staff` | 画面登録オーダーの登録・確定・解除 |
| `adjust_inventory` | `admin` | 棚卸調整 |

### 3.2 DB(`priv/repo/migrations/`、FK の依存順)

| 順 | ファイル | 内容 |
| :-- | :-- | :-- |
| 1 | `{ts}_create_makers_and_warehouses.exs` | `makers`・`warehouses`(`*_code` UNIQUE、`*_name`、`archived_at`、timestamps) |
| 2 | `{ts}_create_items.exs` | `items`(`maker_id` FK `on_delete: :nothing`、`item_code` UNIQUE、`units_per_case` CHECK `>= 1`、`expiration_type`、`archived_at`)、`index(:items, [:maker_id])` |
| 3 | `{ts}_create_inventory_lots.exs` | `inventory_lots`(UNIQUE `(warehouse_id, item_id, expiration_date, received_date)`、CHECK 4 本、`index(:inventory_lots, [:item_id])`) |
| 4 | `{ts}_create_shipment_orders.exs` | `shipment_orders`・`shipment_order_lines`・`shipment_allocations`・`shipment_order_events`、部分ユニーク、CHECK、索引(functional-design §3.1 のとおり) |
| 5 | `{ts}_create_inventory_transactions.exs` | `inventory_transactions`(CHECK `user_id IS NOT NULL OR operator IS NOT NULL`、索引 5 本)、追記専用トリガー(`inventory_transactions` と `shipment_order_events` の UPDATE/DELETE を `RAISE EXCEPTION`) |

- 追加の CHECK: `inventory_lots` に `0 <= allocated_case_qty <= case_qty` と `0 <= allocated_piece_qty <= piece_qty`、`inventory_transactions` に `case_diff <> 0 OR piece_diff <> 0`。`shipment_order_events` に `user_id IS NOT NULL OR operator IS NOT NULL`
- `shipment_orders.external_slip_id` の部分ユニーク索引名: `shipment_orders_external_slip_id_active_index`(`WHERE external_slip_id IS NOT NULL AND status <> 'cancelled'`)。`unique_constraint(..., name: ...)` と対にする(coding-rules §5.7)
- `transaction_type` の enum は `receive` / `ship` / `ship_reverse` / `auto_break` / `transfer_out` / `transfer_in` / `adjust` を最初から全て定義(P1 の値も enum のみ用意)
- `shipment_order_events.event_type` は `created` / `shipped` / `cancelled` / `reversed`

### 3.3 Utils.Calc(純関数)

`lib/food_vault/utils/calc.ex`(新規)

| 関数 | 内容 |
| :-- | :-- |
| `total_pieces(cases, pieces, units_per_case)` | `cases * units_per_case + pieces`。入力が空・不正のときは 0(画面のリアルタイム表示用に `parse_int/1` を併用) |
| `effective(lot)` | `%{cases, pieces, total_pieces}`(現在庫 − 引当済) |
| `expiration_label(date)` | `9999-12-31` なら「期限なし」、それ以外は `YYYY-MM-DD` |
| `parse_int(value)` | 文字列・空文字・nil を非負整数または 0 に |

### 3.4 マスタ(作業単位 A)

`lib/food_vault/makers.ex` + `makers/maker.ex`、`warehouses.ex` + `warehouses/warehouse.ex`、`items.ex` + `items/item.ex`(新規。すべて `use FoodVault.Schema`)

- スキーマ: `maker_code`・`maker_name` 等。`archived_at`、`archived?/1`。`Item` は `belongs_to :maker`、`expiration_type` は `Ecto.Enum, values: [:consumption, :best_before, :none]`。ラベル(消費期限 / 賞味期限 / 管理なし)は `Item.expiration_type_label/1` に 1 か所
- 公開関数(3 Context 共通の形。`Makers` を例示):

| 関数 | 内容 |
| :-- | :-- |
| `list_makers/1`(params) | ページング。`"include_archived"` が無ければ有効のみ |
| `all_makers/0` | 有効のみ(画面の選択肢用。コード順) |
| `get_maker!/1` | 取得 |
| `change_maker/2`、`create_maker/2`(scope, attrs)、`update_maker/3`(scope, maker, attrs) | `:manage_masters` が無ければ `{:error, :forbidden}`。`unique_constraint` で重複を changeset エラーにする |
| `archive_maker/2`、`restore_maker/2` | 状態遷移。アーカイブ規則違反は `{:error, :has_active_items}` 等のアトム |

- `Items.update_item/3`(Repo.transact): ① `items` を `FOR UPDATE` で再読込 → ② `units_per_case` または `expiration_type` が変更される場合のみ、`InventoryLot` が 1 件でもあれば `{:error, :lots_exist}`。入荷側は `items` を `FOR SHARE` で読む(§3.5)ため競合しない
- アーカイブ規則:
  - `Items.archive_item/2`: ① `FOR UPDATE` ② 全ロットが現在庫 0(`case_qty = 0 AND piece_qty = 0`)③ `allocated` オーダーの明細に含まれない → 違反は `{:error, :has_stock}` / `{:error, :has_allocation}`
  - `Warehouses.archive_warehouse/2`: 全ロットが在庫 0 かつ引当 0。`allocated` オーダーの出庫倉庫でもないこと
  - `Makers.archive_maker/2`: 有効な商品が無いこと(`{:error, :has_active_items}`)
  - 復帰は `archived_at = NULL`。商品を復帰するときはメーカーが有効であること(`{:error, :archived_maker}`)
- 他 Context への依存: `Items` が `Inventories`・`ShipmentOrders` のスキーマを参照するクエリを持つ。Context 間の呼び出しは `Inventories.any_lots?/1` 等の公開関数経由にする(スキーマの直接 `Repo` 参照を避ける)

### 3.5 入荷・在庫・受払履歴(作業単位 B)

`lib/food_vault/inventories.ex` + `inventories/inventory_lot.ex`・`inventory_transaction.ex`(新規)

- `InventoryLot`: `belongs_to :warehouse/:item`、数量 4 列。`check_constraint` を changeset に対で書く
- `InventoryTransaction`: `belongs_to :lot`・`:shipment_order`(`shipment_order_id`)・`:user`。`transaction_type` は `Ecto.Enum`。`insert_changeset/2` のみ

公開関数:

| 関数 | 内容 |
| :-- | :-- |
| `receive_inventory(actor, attrs)` | 入荷(§5.2)。戻り `{:ok, %{lot: lot, transaction: tx}}`。下記の手順 |
| `list_inventory_lots(params)` | ロット一覧(ページング)。フィルタ: `warehouse_id`・`item_id`・`expiration_from`/`expiration_to`・`"include_empty"`(既定は在庫 0 を除外)。`preload: [:warehouse, item: :maker]`、並びは `expiration_date, received_date, id` 昇順 |
| `list_inventory_summaries(params)` | 商品別の集計(倉庫 × 商品。現在庫・引当・有効在庫の合算)。ロット別の `Calc` と同じ表示列 |
| `get_inventory_lot!/1` | `preload` 付き |
| `list_inventory_transactions(params)` | 受払履歴(ページング)。フィルタ: `lot_id`・`item_id`・`warehouse_id`・`from`/`to`(JST の日付を UTC 範囲に変換)・`transaction_type`・`user_id`。新しい順 |
| `change_receipt(attrs)` | 入荷フォーム用(embedded でなくスキーマレス changeset。`Ecto.Changeset.cast/4` + `{data, types}`) |
| `lock_items(multi, name, item_ids)`・`lock_lots(multi, name, lot_query)`・`record_transaction(multi, name, attrs)` | **ShipmentOrders・棚卸調整と共用**する Multi の部品(§3.1 architecture)。ロックキー順は `lock_lots` に 1 か所だけ書く |

`receive_inventory/2` の手順(1 つの `Repo.transact`):

1. `warehouse_id`・`item_id` を検証(存在しアーカイブ済みでない)。アーカイブ済みは `{:error, changeset}`(`warehouse_id`/`item_id` にエラー)
2. `items` を `FOR SHARE` で読み、`expiration_type` で期限日を確定(`none` は `9999-12-31`、それ以外は必須)
3. `case_qty >= 0`・`piece_qty >= 0`・合計 > 0 を検証(0/0 の入荷は拒否)
4. `Repo.insert(lot, on_conflict: [inc: [case_qty: n, piece_qty: m]], conflict_target: [:warehouse_id, :item_id, :expiration_date, :received_date], returning: true)`
5. `inventory_transactions` に `receive`(`case_diff = n`、`piece_diff = m`、actor の `user_id`/`operator`)を追加

### 3.6 出庫オーダーの引当(作業単位 C)

`lib/food_vault/shipment_orders.ex` + `shipment_orders/{shipment_order,shipment_order_line,shipment_allocation,shipment_order_event,allocation_plan}.ex`(新規)

- スキーマ: `ShipmentOrder`(`status` は `Ecto.Enum`、`has_many :lines`・`:events`)、`ShipmentOrderLine`(`has_many :allocations`)、`ShipmentAllocation`(`belongs_to :lot`)、`ShipmentOrderEvent`(`insert_changeset` のみ)
- `ShipmentOrders.AllocationPlan`(純粋関数、Schema ではない補助モジュール):
  - `plan_line(lots, units_per_case, req_cases, req_pieces)` → `{:ok, %{allocations: [%{lot_id, cases, pieces}], breaks: [%{lot_id, cases: k, pieces: k * upc}]}}` または `{:shortage, %{cases: n, pieces: m}}`
  - `lots` は呼び出し側が**先出し順**に並べたロット構造体(有効数量は `Calc.effective/1`)
  - ステップ 1(ケース): 各ロットの有効ケース数から `req_cases` を満たすまで取る
  - ステップ 2(バラ): ロット順に ① 有効バラ(`piece_qty − allocated_piece_qty`)から取る ② 残りがあり有効ケース(ステップ 1 で引当済みの分を引いた値)> 0 なら `k = min(有効ケース, ceil(残り ÷ upc))` を荷崩し(`case_qty -= k`・`piece_qty += k × upc`)して取る ③ まだ足りなければ次のロットへ
  - ステップ 1 とステップ 2 で同じロットから取った分は、`allocations` の 1 行に合算する
  - 荷崩しはロットごとに 1 行(複数ケース開封でも合算)
- 公開関数:

| 関数 | 内容 |
| :-- | :-- |
| `allocate_shipment_order(actor, attrs)` | 引当(§5.3)。`attrs`: `"warehouse_id"`・`"shipment_date"`・`"lines"`(`item_id`・`req_cases`・`req_pieces`・任意 `min_expiration_date`)・任意 `"external_slip_id"`。戻り `{:ok, %{shipment_order: order, replayed?: boolean}}`、不足は `{:error, :insufficient_stock, shortages}`(`[%{item_id, shortage_cases, shortage_pieces}]`、全明細分)、`{:error, :validation_failed, errors}`、`{:error, :idempotency_conflict}`、`{:error, :forbidden}` |
| `list_shipment_orders/1` | ページング。フィルタ: `status`・`warehouse_id`・`shipment_date`・`origin`(`screen` / `external`) |
| `get_shipment_order!/1` | `preload: [:warehouse, lines: [:item, allocations: :lot], events: :user]` |
| `change_shipment_order/1` | 登録フォーム用 |

- 手順(1 つの `Repo.transact`):
  1. 冪等チェック(`external_slip_id` あり): 同一 ID の非 `cancelled` が存在すれば正規化比較して一致なら `{:ok, %{shipment_order: existing, replayed?: true}}`(イベント追加なし)、不一致は `{:error, :idempotency_conflict}`
  2. 入力検証: 倉庫・商品が有効、明細の `item_id` 重複なし、`req_cases >= 0`・`req_pieces >= 0`・合計 > 0、`min_expiration_date` は日付
  3. 明細を `item_id` 昇順に並べ替え、`Inventories.lock_items`(`FOR SHARE`、`item_id` 昇順)
  4. 対象ロットを **1 クエリ**で `FOR UPDATE`(`warehouse_id = ^w and item_id in ^item_ids and expiration_date >= GREATEST(^shipment_date, COALESCE(min, shipment_date))`)。`min_expiration_date` は明細ごとに異なるため、条件は `OR` で結合するのではなく**明細ごとの下限を後段のフィルタで適用**し、クエリは `expiration_date >= ^shipment_date` のロットを全て取る(ロックの範囲は広くなるが、ロックキー順と 1 クエリ制約を守る)
  5. 明細ごとに `plan_line`(`min_expiration_date` を適用したロットのみ渡す)。不足は集める
  6. 不足が 1 つでもあれば `Repo.rollback({:insufficient_stock, shortages})`
  7. なければ、オーダー・明細・引当明細を保存し、荷崩しロットを UPDATE(`case_qty`・`piece_qty`)、引当ロットの `allocated_case_qty`/`allocated_piece_qty` を加算、`auto_break` を 1 ロット 1 行、`created` イベントを記録
  8. 部分ユニーク違反は `Repo.rollback` せずトランザクションの外で既存を再取得し、1 と同じ比較をする
- ロット UPDATE は `Repo.update_all(from(l in InventoryLot, where: l.id == ^id), inc: [...])` ではなく、**ロック済みの値から計算した絶対値**で更新する(CHECK 違反時はエラーにして 500 にしない)。`check_constraint` 違反は `{:error, :insufficient_stock, ...}` ではなく、プログラムエラーとして例外にする(ロック済みなので発生しない設計)

### 3.7 出庫確定・引当解除(作業単位 D)

`ShipmentOrders` に追加:

| 関数 | 内容 |
| :-- | :-- |
| `ship_shipment_order(actor, order)` | 確定(§5.4)。戻り `{:ok, %{shipment_order: order, replayed?: boolean}}`。すでに `shipped` なら `replayed?: true`(履歴を追加しない)。`allocated` 以外は `{:error, :invalid_state}`。`external_slip_id` ありのオーダーを `%User{}` actor で確定すると `{:error, :forbidden}` |
| `cancel_shipment_order(actor, order, opts \\ [])` | 引当解除(§5.5)。同様に冪等。`opts` の `reason` は任意(発送システム起源の API で記録)。引当明細は削除しない |

- どちらも ① オーダーを `FOR UPDATE` で再読込して状態を確認 ② 引当明細の `lot_id` を **1 クエリでロック**(ロックキー順)③ 数量を更新 ④ 受払履歴(`ship` はロット単位)・オーダー履歴を追加 ⑤ ステータスを更新
- 確定の `ship` は `case_diff = -allocated_cases`・`piece_diff = -allocated_pieces`、`shipped_at` は現在時刻(UTC)
- `ShipmentOrder.origin/1`(`:screen` | `:external`)を 1 か所に置く

### 3.8 棚卸調整(作業単位 E)

`Inventories` に追加:

| 関数 | 内容 |
| :-- | :-- |
| `adjust_inventory(actor, lot, attrs)` | `attrs`: `"case_diff"`・`"piece_diff"`・`"note"`(必須)。戻り `{:ok, %{lot: lot, transaction: tx}}`。ロットを `FOR UPDATE` で再読込し、①差分が 0/0 は拒否 ②反映後の `case_qty`・`piece_qty` が 0 以上かつ引当済数以上(有効在庫を下回らない)③ `adjust` を記録 |
| `change_adjustment(lot, attrs)` | フォーム用(スキーマレス changeset) |
| `list_allocating_orders(lot)` | そのロットを引き当てている `allocated` オーダー(ロット詳細用) |

- 荷まとめと入荷訂正は**特別な関数を作らず**、`case_diff`/`piece_diff` の組合せで表現する(`case_diff = +k`・`piece_diff = -k × upc`。入荷訂正の期限日・入荷日の誤りは別ロットへの全数減算と再入荷。画面に説明を出す)。画面に「荷まとめ」ボタンは設けず、フォームの下に `Calc` で換算ヘルパーを置く(例: 「バラ → ケース k」を入力すると両差分を自動入力)

### 3.9 Web: ルーティングと画面

`lib/food_vault_web/router.ex` を変更。既存の `get "/"` はそのまま。

```elixir
scope "/", FoodVaultWeb do
  pipe_through [:browser, :require_authenticated_user]
  live_session :require_authenticated_user, on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated}] do
    live "/inventory_lots", InventoryLotLive.Index, :index
    live "/inventory_lots/:id", InventoryLotLive.Show, :show
    live "/inventory_transactions", InventoryTransactionLive.Index, :index
    live "/shipment_orders", ShipmentOrderLive.Index, :index
    live "/shipment_orders/:id", ShipmentOrderLive.Show, :show
    live "/masters/makers", MakerLive.Index, :index        # 参照は全ロール
    live "/masters/warehouses", WarehouseLive.Index, :index
    live "/masters/items", ItemLive.Index, :index
  end
end

# staff 以上
scope "/", FoodVaultWeb do
  pipe_through [:browser, :require_authenticated_staff_user]   # 新設(下記)
  live_session :require_authenticated_staff, on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated_staff}] do
    live "/inventory_receipts/new", InventoryReceiptLive.Form, :new
    live "/shipment_orders/new", ShipmentOrderLive.Form, :new
  end
end

# admin
scope "/management", FoodVaultWeb.Management do
  # 既存の live_session に追加
  live "/makers/new", MakerLive.Form, :new
  live "/makers/:id/edit", MakerLive.Form, :edit
  # warehouses・items も同形
  live "/inventory_lots/:id/adjustments/new", InventoryAdjustmentLive.Form, :new
end
```

- マスタの一覧は全ロールが `/masters/...` で参照。編集・アーカイブ・復帰は `/management/...` の admin 専用。一覧の「編集」ボタンは `Permission.can?(user, :manage_masters)` で出し分け
- `require_authenticated_staff` plug は存在しない。staff 用の `scope` では、`:ensure_authenticated_staff` の on_mount のみでなく HTTP 接続の初回描画も保護する必要があるため、`UserAuth` に `require_authenticated_staff_user/2`(`staff` 以上。不許可は `put_flash(:error, "権限がありません。")` で `/` へ)を追加する(admin 用の plug と同形)
- `UserAuth` 以外の既存ファイルの変更は最小にする

画面(各 `lib/food_vault_web/live/{resource}_live/`):

| ディレクトリ | 画面 | 主な内容 |
| :-- | :-- | :-- |
| `inventory_lot_live/` | `index.ex` | 在庫一覧。表示切替「ロット別 / 商品別」、フィルタ(倉庫・商品・期限範囲・在庫 0 を含む)。`ケース数 ｜ バラ数 ｜ 総バラ数`・引当済・有効在庫。期限の近い順。「入荷登録」リンクは `receive_inventory` 権限がある場合のみ |
| | `show.ex` | ロット詳細。数量、引当しているオーダー(作業単位 E で表示)、直近の受払履歴。admin には「棚卸調整」リンク |
| `inventory_receipt_live/` | `form.ex` | 入荷登録。倉庫・商品(有効のみ)・期限日(`none` 商品は無効化して「期限なし」)・入荷日・ケース数・バラ数。`phx-change` で `Calc.total_pieces` を使って「総数:〇〇 個」を表示。送信で `Inventories.receive_inventory/2`、成功時に `OperationLog.info`、在庫一覧へ遷移 |
| `inventory_transaction_live/` | `index.ex` | 受払履歴の検索。出庫オーダー(`/shipment_orders/:id`)へのリンク、`transfer_id`、操作者(ユーザー名または `operator`) |
| `shipment_order_live/` | `index.ex` | 一覧。状態・倉庫・出庫予定日・起源(画面 / 発送システム)で絞り込み |
| | `show.ex` | 詳細。引当ロット(期限日 × 数量)、オーダー履歴、確定・取消ボタン(`staff` 以上かつ画面登録オーダー)。発送システム起源のオーダーは「発送システムと状態がずれます」の警告を出し、操作ボタンは出さない |
| | `form.ex` | 登録。倉庫・出庫予定日・明細(商品と `req_cases`/`req_pieces`、任意の最低許容期限日)。明細行の追加・削除。不足時は `shortages` を表を使って一覧表示 |
| `management/` | `maker_live/`・`warehouse_live/`・`item_live/` の `form.ex` | 登録・編集。アーカイブ・復帰は一覧(`/masters/...`)の `handle_event` から。`items` の編集では、`{:error, :lots_exist}` のとき「ロットがあるため変更できません」を表示 |
| | `inventory_adjustment_live/form.ex` | 棚卸調整。ロット情報、ケース差・バラ差、理由、換算ヘルパー、プレビュー(調整後の数量・有効在庫) |

- すべての `handle_event` の先頭で `Permission.can?(@current_scope.user, action)` を検査し、不許可は `put_flash(:error, "権限がありません。")`(coding-rules §9.8 の flash 3 分岐に従う)
- ナビゲーション: `Layouts.app` のヘッダーに「在庫一覧」「受払履歴」「出庫オーダー」「マスタ」「入荷登録(staff 以上)」「棚卸調整は在庫詳細から」を追加。リンク先は `~p` のパスのみ。`core_components.ex` は改変しない
- 業務用コンポーネントは `lib/food_vault_web/components/inventory_components.ex`(新規): 数量 3 列セルの `quantity_cell/1`、起源バッジなど

### 3.10 seeds

- `priv/repo/seeds.exs` に開発用のマスタ(メーカー 2・倉庫 2・商品 3 件。期限区分 3 種を 1 件ずつ)を追加。冪等(コードで `get_by` して無ければ作る)。入荷データは作らない

## 4. テスト

| ファイル | 内容 |
| :-- | :-- |
| `test/support/fixtures/{makers,warehouses,items,inventories,shipment_orders}_fixtures.ex` | Context の公開 API 経由で作る(`maker_fixture`・`warehouse_fixture`・`item_fixture`・`lot_fixture`・`order_fixture`) |
| `test/food_vault/utils/calc_test.exs` | `async: true`。総バラ数、有効在庫、期限なしのラベル、入力の変換 |
| `test/food_vault/{makers,warehouses,items}_test.exs` | 作成・重複・権限、アーカイブ規則(商品・倉庫・メーカー)、ロットがあるときの入数・期限区分変更拒否、`FOR UPDATE`/`FOR SHARE` の競合(入荷との並行) |
| `test/food_vault/inventories_test.exs` | 入荷(新規・加算・`none` 商品・必須期限・アーカイブ済み・権限・受払履歴・操作者)、同時入荷の加算(複数プロセス)、一覧のフィルタと並び順、受払履歴の検索、棚卸調整(理由必須・有効在庫を下回る減算の拒否・荷まとめ・入荷訂正) |
| `test/food_vault/shipment_orders/allocation_plan_test.exs` | 純粋関数。先出し順、ケース要求、バラ要求、荷崩しの算術(`k`)、複数ロットにまたがる引当、不足の数 |
| `test/food_vault/shipment_orders_test.exs` | 引当(期限切れ・最低許容期限日未満のロット除外、荷崩しの `auto_break` 1 行、不足時のロールバックと全明細分の不足数、`external_slip_id` の冪等と不一致、部分ユニーク、並行引当で引当済数が現在庫を超えない、商品順が逆の複数明細の同時引当でデッドロックしない)、確定(数量・履歴・冪等)、解除(引当済数のみ戻る・引当明細が残る・冪等)、発送システム起源の画面確定の拒否、状態不正 |
| `test/food_vault_web/live/**` | 各画面のロール別(`viewer`/`staff`/`admin`)の許可・拒否(on_mount・`handle_event`)、フォーム入力、総バラ数のリアルタイム表示、DB の書き込みの検証 |
| `test/food_vault_web/user_auth_test.exs` | `require_authenticated_staff_user` の許可・拒否を追加 |
| `test/food_vault/utils/permission_test.exs` | 追加 action の許可マトリクス |

- 並行テストは `Ecto.Adapters.SQL.Sandbox` の `:shared` モードで、`Task.async_stream` を使って複数プロセスで実行する(`async: false`)
- DB の追記専用トリガーは、`Repo.update_all`/`delete_all` が例外になることをテストで確認する

## 5. 影響範囲と更新するドキュメント

- 影響範囲: `food_vault` のみ。`food_ship` に変更は無い。既存の認証・ユーザー管理のコードは `UserAuth`(`require_authenticated_staff_user/2` の追加)と `Layouts`(ナビゲーション)と `Permission`(action の追加)以外を変えない
- 作業完了後に更新する永続ドキュメント: `repository-structure.md`(§3.1〜3.4 の「［計画］」を「［現状］」に)、`architecture.md`(§3.2 の Context 表、§16 の未決事項)、`development-guidelines.md`(§1.4 の段階 2 に「完了」)、`glossary.md`(追加用語)

## 6. 決定した未確定事項(requirements.md の「未確定」への回答)

| 項目 | 決定 |
| :-- | :-- |
| Context の分割と戻り値 | §2・§3.4〜3.8 のとおり |
| ページング | `scrivener_ecto`、ページサイズ 20 |
| 入荷日の既定 | 今日(JST) |
| URL 体系 | §3.9 のとおり(一般は `/inventory_lots` 等、admin は `/management/...`) |
| seeds | 開発用マスタを追加(入荷データは作らない) |
| 並行テスト | `:shared` モード + `Task.async_stream` |
