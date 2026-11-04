# タスクリスト: 在庫側の核(段階 2)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。対象は `food_vault` のみ。コマンドは必ずコンテナ経由(`docker compose run --rm food_vault_web mix ...`)。単位ごとに品質ゲート(compile `--warnings-as-errors`・format・`credo --all`・test)を通してコミット・プッシュし、進捗に合わせてチェックを更新する。

## 0. 共通基盤

- [x] 実行環境の確認(`docker compose build` はプロキシの CA 未登録で失敗するため、`elixir:1.20.5-otp-29` と `postgres:15.2` を `--network host` で直接起動し、`/root/.ccr/ca-bundle.crt` を `SSL_CERT_FILE`・`HEX_CACERTS_PATH`・git の `http.sslCAInfo` に設定して `mix test` を実行した)
- [x] `scrivener_ecto` を追加し、`Repo` に `use Scrivener, page_size: 20`(取得できなければ自作の `paginate` に切り替える)
- [x] `Utils.Calc`(`total_pieces`・`effective`・`expiration_label`・`parse_int`)とテスト
- [x] `Permission` に `manage_masters`・`receive_inventory`・`manage_shipment_order`・`adjust_inventory` を追加し、テストを更新
- [x] `UserAuth.require_authenticated_staff_user/2` を追加し、テストを書く
- [x] `Layouts.app` に業務ナビゲーションを追加(単位ごとにリンクを追加。単位 A はマスタ 3 画面)

## 1. 単位 A: マスタ管理(F-V1)

- [x] migration: `makers`・`warehouses`、`items`
- [x] `Maker`・`Warehouse`・`Item` スキーマ(`use FoodVault.Schema`、`Ecto.Enum`、`unique_constraint`、ラベル関数)
- [x] `Makers`・`Warehouses`・`Items` Context(CRUD、`Scope` 第 1 引数、権限検査、アーカイブ・復帰、`Items.update_item` の `FOR UPDATE` とロット存在ガード、アーカイブ規則)
- [x] 規則の検査に必要な `Inventories.item_has_lots?/1`・`item_has_stock?/1`・`warehouse_has_stock?/1` を置く。`inventory_lots` の migration とスキーマは単位 A で先に作成した(在庫 0 のロットは引当済数も 0 のため、「`allocated` オーダー明細に含まれない」条件は在庫 0 の検査で満たされる)
- [x] フィクスチャ(`maker_fixture`・`warehouse_fixture`・`item_fixture`)
- [x] 画面: `/masters/makers|warehouses|items`(全ロール参照、アーカイブ・復帰の `handle_event`)、`/management/.../new|edit`(admin のフォーム)
- [x] `router.ex`(全ロール `live_session`、admin 側の追加)
- [x] テスト(Context・LiveView のロール別)、品質ゲート、コミット・プッシュ

## 2. 単位 B: 入荷・在庫一覧・受払履歴(F-V2・F-V6)

- [x] migration `inventory_lots`(CHECK)は単位 A で作成済み
- [x] migration: `inventory_transactions`(CHECK・索引)。追記専用トリガー関数 `forbid_update_delete()` と `inventory_transactions` のトリガーを作る(`shipment_order_events` のトリガーは単位 C)
- [x] `InventoryTransaction` スキーマ(`InventoryLot` は単位 A で作成済み)
- [x] `Inventories`: `receive_inventory/2`(`FOR SHARE`、期限日の確定、`ON CONFLICT` 加算、`receive` 記録)、`list_inventory_lots/1`・`list_inventory_summaries/1`・`get_inventory_lot!/1`・`list_inventory_transactions/1`、共用部品 `lock_items`・`lock_lots`・`record_transaction`
- [x] `Items`・`Warehouses` のアーカイブ規則に実ロットを接続する
- [x] フィクスチャ(`lot_fixture`)と、実コミットで並行テストを行う `ConcurrencyCase`(`sandbox: false`、テスト後に `TRUNCATE`)
- [x] `Utils.ConvertDatetime`(JST 変換。入荷日の既定と期間検索で使用)
- [x] 画面: `inventory_receipt_live/form.ex`(総数のリアルタイム表示)、`inventory_lot_live/index.ex`・`show.ex`、`inventory_transaction_live/index.ex`、`inventory_components.ex`
- [x] テスト(入荷の新規・加算・同時入荷、フィルタ、受払履歴、LiveView のロール別)、品質ゲート、コミット・プッシュ

## 3. 単位 C: 出庫オーダーの引当(F-V3 前半)

- [ ] migration: `shipment_orders`・`shipment_order_lines`・`shipment_allocations`・`shipment_order_events`(部分ユニーク・CHECK・追記専用トリガー)
- [ ] スキーマ 4 種と `AllocationPlan`(純粋関数)とそのテスト
- [ ] `ShipmentOrders.allocate_shipment_order/2`(冪等、検証、`FOR SHARE`/`FOR UPDATE`、荷崩し、ロールバック、不足の全明細分)、`list_shipment_orders/1`・`get_shipment_order!/1`・`change_shipment_order/1`
- [ ] フィクスチャ(`order_fixture`)
- [ ] 画面: `shipment_order_live/index.ex`・`show.ex`(閲覧のみ)・`form.ex`(登録)
- [ ] テスト(先出し順・期限条件・荷崩し・不足・冪等・並行・デッドロック、LiveView のロール別)、品質ゲート、コミット・プッシュ

## 4. 単位 D: 出庫確定・引当解除(F-V3 後半)

- [ ] `ship_shipment_order/2`・`cancel_shipment_order/3`(冪等、起源による拒否、受払・オーダー履歴)
- [ ] `show.ex` に確定・取消ボタンと `handle_event`(権限検査、`OperationLog`)、発送システム起源の警告
- [ ] テスト(数量・履歴・冪等・引当明細の保持・起源拒否・LiveView のロール別)、品質ゲート、コミット・プッシュ

## 5. 単位 E: 棚卸調整(F-V5)

- [ ] `Inventories.adjust_inventory/3`・`change_adjustment/2`・`list_allocating_orders/1`
- [ ] 画面: `management/inventory_adjustment_live/form.ex`(換算ヘルパー、プレビュー)、ロット詳細に引当オーダーと調整リンク
- [ ] テスト(理由必須・有効在庫を下回る拒否・荷まとめ・入荷訂正・権限)、品質ゲート、コミット・プッシュ

## 6. 仕上げ

- [ ] `seeds.exs` に開発用マスタを追加(冪等)
- [ ] `make check` を両アプリで実行し、`food_ship` に影響が無いことを確認
- [ ] 永続ドキュメントを更新(`repository-structure.md`・`architecture.md`・`development-guidelines.md`・`glossary.md`)
- [ ] requirements.md の受け入れ条件を照合し、tasklist を完了にする
