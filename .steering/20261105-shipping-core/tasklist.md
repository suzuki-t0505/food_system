# タスクリスト: 発送側 P0(段階 4)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。対象は `food_ship` のみ。単位ごとに品質ゲート(compile `--warnings-as-errors`・format・`credo --all`・test)を通してコミット・プッシュし、進捗に合わせてチェックを更新する。

実行環境: `docker compose` で `docker compose run --rm food_ship_web mix ...`(SessionStart フックが用意した `COMPOSE_FILE="docker-compose.yml:scripts/cloud/docker-compose.cloud.yml"`)。ビルドできない場合は段階 3 と同様に `elixir:1.20.5-otp-29` と `postgres:15.2` を `--network host` で直接起動し、`/root/.ccr/ca-bundle.crt` を `SSL_CERT_FILE`・`HEX_CACERTS_PATH` に設定して `mix` を実行する。

## 0. 実行環境

- [x] テスト実行環境を用意し、既存の `food_ship` の `mix test` が通ることを確認する(初回は `mix deps.get` が必要)
- [x] `req` のバージョンと `Req.Test`(共有モード・`allow/3`)の使い方を確認する(design §12)

## 1. 単位 A: 基盤・`Inventory.Client`

- [x] `Utils.ConvertDatetime`(在庫側のコピー)・`Utils.Calc`(`total_piece_qty`・`default_box_count`・`min_expiration_date`)とテスト
- [x] `Utils.Permission` に `manage_masters`・`manage_shipping_slips`・`pack_shipping_slips` と `authorize/2` を追加し、テストを更新
- [x] `config/runtime.exs`(`FoodShip.Inventory.Client` の設定。本番は `INVENTORY_API_BASE_URL`・`INVENTORY_API_TOKEN` が未設定なら `raise`、`INVENTORY_WAREHOUSE_ID` は空なら `nil`)、`config/test.exs`(固定値・`retry_base_ms: 0`・`req_options` のスタブ)
- [x] `FoodShip.Inventory.Client`(`allocate/1`・`ship_order/2`・`cancel_order/3`・`get_order/1`・`list_orders_by_slip/1`・`find_item/1`、共通エラーの変換、リトライ、`:api` ログ)
- [x] `Client` のテスト(成功・各エラー・リトライの対象と対象外・接続エラー・不正な本文・`Authorization`/`operator`・トークンがログに出ない)
- [x] テスト用スタブヘルパー(`test/support/inventory_stub.ex`)
- [x] `docker-compose.yml` に発送側の `INVENTORY_*` を追加、`food_ship/README.md` に倉庫 ID の設定手順を追記
- [x] `router.ex` に `require_authenticated_staff_user` plug があるか確認し、無ければ追加(`UserAuth`・テスト)
- [x] 品質ゲート、コミット・プッシュ

## 2. 単位 B: マスタ(F-S1)

- [x] migration(`clients`・`shipping_items`・`expiration_rules`、`unique_index`・FK 索引・CHECK)
- [x] `FoodShip.Clients`(+ `Clients.Client`)・テスト(CRUD・アーカイブ・復帰・一意制約・権限)
- [x] `FoodShip.ShippingItems`(+ `ShippingItem`)・テスト(CRUD・アーカイブ・`fetch_inventory_item/1`・`refresh_from_inventory/2`・在庫側にない商品コード・通信失敗)
- [x] `FoodShip.ExpirationRules`(+ `ExpirationRule`)・テスト(CRUD・物理削除・一意制約・アーカイブ済みを選べない)
- [x] 参照一覧 LiveView 3 つ(`/masters/...`、全ロール)とテスト
- [x] 編集フォーム LiveView 3 つ(`/management/...`、`admin`。発送商品は「商品コードで取得」を `Task` で)とテスト(権限・イベントの直接送信の拒否)
- [x] `router.ex` にルート、`Layouts` のナビにマスタへのリンクを追加
- [x] マスタ用フィクスチャ(Context の公開 API 経由)
- [x] 品質ゲート、コミット・プッシュ
- 実装メモ: マスタ一覧はページングしない(件数が少ない前提。在庫側のような `scrivener_ecto` は入れず `Repo.all`)。`Layouts.app` に `wide` 属性とマスタのナビを追加した。`FoodShipWeb.InventoryMessages`(在庫 API エラーの文言)と `FoodShipWeb.MasterComponents` を追加した

## 3. 単位 C: 伝票登録・引当・再引当(F-S2)

- [ ] migration(`shipping_slips`・`slip_allocated_lots`・`slip_no` のシーケンス・部分ユニーク・CHECK・索引)
- [ ] `ShippingSlip`・`SlipAllocatedLot` スキーマ(changeset を用途別に。ラベル・`slip_no_label/1`)とテスト
- [ ] `ShippingSlips.AllocationResult`(純粋関数)とテスト
- [ ] `ShippingSlips`: `preview/4`・`change_shipping_slip/2`・`create_shipping_slip/2`・`allocate_shipping_slip/2`・`update_shipping_slip/3`(§5)
- [ ] Context のテスト(`pending` 保存・計算値・二重登録・アーカイブ済み・倉庫未設定・`allocated` とロット保存・`shortage`・各エラーの `allocation_error`・合計不一致・再引当での照会と解除・在庫側 `shipped` の突合・解除失敗で `pending`・`stale`・数量変更で `pending` に戻る・最低許容期限日の再計算)
- [ ] 並行性テスト(同じ伝票の再引当を同時実行。`ConcurrencyCase` を発送側に追加)
- [ ] 伝票フィクスチャ
- [ ] `ShippingSlipLive.Form`(`:new`・`:edit`。リアルタイム計算・箱数の手修正・保存 → `Task` で引当・結果の表示と遷移・確認ダイアログ・倉庫未設定の警告)とテスト(表示と DB の両方、`Req.Test` 共有モード)
- [ ] `router.ex`(staff 以上)
- [ ] 品質ゲート、コミット・プッシュ

## 4. 単位 D: 作業画面・数量変更・取消(F-S3)

- [ ] `ShippingSlips`: `list_shipping_slips/2`・`summarize_ship_dates/1`・`cancel_shipping_slip/2` とテスト(各状態・解除失敗でローカルが変わらない・在庫側 `shipped` は拒否)
- [ ] `ShippingSlipLive.Index`(タブ・残件数・フィルタ・伝票行・引当ロット表示・エラー表示・ハイライト・`busy`・再引当・取消・数量変更リンク)
- [ ] `ShippingSlipLive.Components`(状態バッジ・ロット表示・エラー表示)
- [ ] `/` を作業画面へ redirect、`Layouts` のナビに「作業画面」「伝票登録」を追加し、`page_controller` のテストを更新
- [ ] LiveView のテスト(表示・フィルタ・`viewer` に操作が無い・イベント直接送信の拒否・取消の記録・再引当で復旧)
- [ ] 例外ケース(§6.11 ①②⑤⑦)のテストが揃っていることを確認
- [ ] 品質ゲート、コミット・プッシュ

## 5. 単位 E: 梱包完了(F-S4)

- [ ] `ShippingSlips`: `pack_shipping_slip/2`・`update_box_count/3` とテスト(成功・409 → 照会で `shipped` なら `packed`・それ以外はエラー・在庫停止時に `allocated` のまま・復旧後の再実行・箱数の検証)
- [ ] `ShippingSlipLive.Index` に「梱包完了」(確認ダイアログ・`busy`・グレーアウト)と箱数のインライン編集を追加、テスト
- [ ] 例外ケース(§6.11 ⑧)のテスト
- [ ] 品質ゲート、コミット・プッシュ

## 6. 仕上げ

- [ ] 画面の動作確認(両アプリを起動し、在庫側で入荷 → 発送側で登録・引当・梱包完了まで。ブラウザで確認できない場合はその旨を記録する)
- [ ] 両アプリで品質ゲート(`food_vault` が影響を受けていないこと)
- [ ] 永続ドキュメントの更新(design §11。承認を得て行う): `functional-design.md`・`architecture.md`・`repository-structure.md`・`development-guidelines.md`(段階 4 を「完了」)・`glossary.md`・`infra/terraform/README.md`
- [ ] 本ファイルの全項目を完了にし、コミット・プッシュ
