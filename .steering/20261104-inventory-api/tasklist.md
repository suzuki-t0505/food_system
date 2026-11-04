# タスクリスト: 在庫 API(段階 3)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。対象は `food_vault` のみ。単位ごとに品質ゲート(compile `--warnings-as-errors`・format・`credo --all`・test)を通してコミット・プッシュし、進捗に合わせてチェックを更新する。

実行環境: `docker compose` はビルドできないため、段階 2 と同様に `elixir:1.20.5-otp-29` と `postgres:15.2` を `--network host` で直接起動し、`/root/.ccr/ca-bundle.crt` を `SSL_CERT_FILE`・`HEX_CACERTS_PATH` に設定して `mix` を実行する。

## 0. 実行環境

- [x] テスト実行環境を用意し、既存の `mix test`(380 件)が通ることを確認する(SessionStart フックが用意した `COMPOSE_FILE="docker-compose.yml:scripts/cloud/docker-compose.cloud.yml"` で `docker compose run --rm food_vault_web mix ...`。初回は `mix deps.get` が必要)

## 1. 単位 A: 認証・基盤

- [x] `config/runtime.exs`(`INVENTORY_API_TOKENS`、dev の既定値、prod の未設定で `raise`)、`config/test.exs`(テスト用トークン 2 つ)
- [x] `FoodVaultWeb.Plugs.ServiceTokenAuth`(`valid_token?/1`、401、`:api` ログ)とテスト
- [x] `FoodVaultWeb.Api.ErrorResponse`。`ApiFormat` plug は効果がなかったため採用せず、`config.exs` の `render_errors` を JSON 先頭にした(design.md §2 に理由)。一度コミットした `ApiFormat` は単位 B で削除
- [x] `ErrorJSON` を共通形式に変更し、テストを更新
- [x] `OperationLog` が `api_operator` を操作者として扱うようにし、テストを追加
- [x] `router.ex` の `pipeline :api` に `ServiceTokenAuth` を追加(`/api/v1` スコープは単位 B で Controller と同時に追加する。未定義モジュールの警告を避けるため)
- [x] `ConnCase` に API 用ヘルパー(トークン付与)を追加
- [x] 品質ゲート、コミット・プッシュ

## 2. 単位 B: ① 出庫引当・⑤ 照会

- [x] `ShipmentOrders`: `fetch_shipment_order/1`、`list_shipment_orders_by_slip/1`、`idempotency_conflict` が既存オーダーを返す形に変更(テストの更新と追加)
- [x] `FoodVaultWeb.Api.Operator`、`FallbackController`
- [x] `ShipmentOrderJSON`(共通のオーダー表現・一覧)
- [x] `ShipmentOrderController`: `create`・`show`・`index`
- [x] テスト(① の 201/200/409/422、⑤ の `:id` と `?external_slip_id=`、認証なし 401、壊れた JSON・存在しないルート・`reverse` の JSON 404、同時 POST の冪等)
- [x] 品質ゲート、コミット・プッシュ

## 3. 単位 C: ② 出庫確定・③ 引当解除

- [ ] `ShipmentOrderController`: `ship`・`cancel`(`operator`・`reason` の検証、`OperationLog`)
- [ ] テスト(状態遷移・冪等・`invalid_state`・404・発送システム起源の確定・解除・履歴に `operator` が残る)
- [ ] 品質ゲート、コミット・プッシュ

## 4. 単位 D: ⑥ 倉庫・⑦ 商品

- [ ] `Items.search_active_items/1` とテスト
- [ ] `WarehouseController`・`ItemController` と JSON ビュー
- [ ] テスト(有効のみ、`item_code` 絞り込み、`maker_id`・`maker_name`)
- [ ] 品質ゲート、コミット・プッシュ

## 5. 仕上げ

- [ ] `make check` 相当を `food_vault` で実行し、`food_ship` に影響が無いことを確認(`food_ship` のテストも実行)
- [ ] 永続ドキュメントを更新(`functional-design.md`・`architecture.md`・`repository-structure.md`・`development-guidelines.md`・`glossary.md`)
- [ ] requirements.md の受け入れ条件を照合し、tasklist を完了にする
