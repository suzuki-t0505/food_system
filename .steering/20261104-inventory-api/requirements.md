# 要求内容: 在庫 API(段階 3)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 3)、[product-requirements.md F-V4](../../docs/product-requirements.md)、[functional-design.md §7・§9.3](../../docs/functional-design.md)、[architecture.md §6.3・§7](../../docs/architecture.md)
- 対象アプリ: `food_vault`(在庫)のみ。`food_ship` は変更しない(段階 4 が `FoodShip.Inventory.Client` でこの API を呼ぶ)
- 位置づけ: 段階 2(在庫側の核)の次。`ShipmentOrders` Context(引当・確定・解除・冪等)は実装済みで、`{:api, operator}` の actor も受け付ける。**今回は HTTP の層を足すだけ**で、業務ロジックは変えない

## 背景

`/api/v1` のルートも `:api` pipeline の認証も無い(`router.ex` に雛形の `pipeline :api` のみ)。`INVENTORY_API_TOKENS` も `runtime.exs` に無い。Context 側の `external_slip_id` の冪等、`{:error, :insufficient_stock, shortages}`、`{:error, :validation_failed, errors}`、`{:error, :idempotency_conflict}` などの戻り値は段階 2 で用意済み。

## 要求(スコープ)

### API(functional-design §7.1。④ 出庫取消は含めない)

| # | メソッド / パス | 用途 | 成功時 |
| :-- | :-- | :-- | :-- |
| ① | `POST /api/v1/shipment_orders` | 出庫引当 | 201(冪等再送は 200) |
| ② | `POST /api/v1/shipment_orders/:id/ship` | 出庫確定 | 200 |
| ③ | `POST /api/v1/shipment_orders/:id/cancel` | 引当解除 | 200 |
| ⑤ | `GET /api/v1/shipment_orders/:id` / `?external_slip_id=` | 状態・引当結果の照会 | 200 |
| ⑥ | `GET /api/v1/warehouses` | 有効な倉庫の一覧 | 200 |
| ⑦ | `GET /api/v1/items?item_code=` | 有効な商品の検索(省略時は一覧)。`maker_id`・`maker_name` を含む | 200 |

- リクエスト・レスポンスは §7.2 のとおり(共通のオーダー表現を `ShipmentOrderJSON` の 1 か所に定義し ①②③⑤ から使う)

### 認証

- `Authorization: Bearer <token>` のサービストークン認証(`FoodVaultWeb.Plugs.ServiceTokenAuth`)。トークンは環境変数 `INVENTORY_API_TOKENS`(カンマ区切り・複数可)で `runtime.exs` に集約する。未設定なら本番は起動時に落とす。比較は `Plug.Crypto.secure_compare/2`(定数時間)
- トークンの値・`Authorization` ヘッダはログに出さない。不正は 401 `unauthorized`
- `:browser` pipeline(CSRF・セッション)は通さない

### 操作者

- 状態を変える API(①②③)は `operator`(必須、最大 255 文字)を受け取り、`{:api, operator}` の actor として Context に渡す(受払履歴・オーダー履歴に残る)
- 発送システム起源のオーダーの確定・解除は API では許可される(画面では拒否される)

### 冪等性とエラー(§7.3・§7.4)

- ①: 同じ `external_slip_id`(`cancelled` 以外)の再送は、内容が一致すれば 200 で既存を返し、不一致は 409 `idempotency_conflict`(応答に既存の `order_id` と `status`)。同時 POST の競合も 500 にしない
- ②③: すでにその状態なら 200 で現状を返す(履歴は追加しない)。それ以外の状態は 409 `invalid_state`
- エラー形式は全エンドポイント共通の `{ "error": "<code>", "message": "<説明>", ...付加情報 }`。`FallbackController` で Context の戻り値を変換する

| HTTP | `error` | 発生条件 |
| :-- | :-- | :-- |
| 401 | `unauthorized` | トークン不正・未指定 |
| 404 | `not_found` | オーダーが存在しない。パスの ID 形式不正も 404。存在しないルートも同じ形式 |
| 409 | `invalid_state` | 状態遷移として不正 |
| 409 | `idempotency_conflict` | `external_slip_id` の既存オーダーと内容が異なる |
| 422 | `insufficient_stock` | 期限条件を満たす在庫が不足(`shortages` は全明細分、ロールバック済み) |
| 422 | `validation_failed` | 入力不正(数量が負、明細が空、`operator` 欠落、ボディの ID 形式不正、アーカイブ済みの商品・倉庫など)。`errors` に項目別 |

- `GET /api/v1/shipment_orders` は `?external_slip_id=` の照会専用。パラメータなしは 422
- ⑤ `?external_slip_id=` は `{ "shipment_orders": [...] }`(取消済みを含め新しい順、該当なしは空配列で 200)

### 周辺

- 開発用のデフォルトトークンを置く(dev は `runtime.exs` の既定値、test は `test.exs`。本番は環境変数のみで必須)。`docker-compose.yml` は変更しない(発送側と合わせて設定するのは段階 4)
- `:api` カテゴリの Logger で API 呼び出しを記録する(トークンは出さない)。`/api/v1` の書き込みは `OperationLog` に `operator` を残す
- 永続ドキュメントに実装を反映する(`architecture.md`・`repository-structure.md`・`development-guidelines.md`・`functional-design.md`・`glossary.md` のうち影響するもの)

## 受け入れ条件

- [x] 認証: トークンなし・不正は 401 `unauthorized`、正しいトークン(複数のうちいずれか)は通る。`INVENTORY_API_TOKENS` 未設定の本番設定は起動時に失敗する。ブラウザ用の画面・セッションは API の認証に影響しない
- [x] ①: 201 でオーダー表現(`allocations` 付き)を返す。再送(一致)は 200、不一致は 409 `idempotency_conflict`(`order_id`・`status` 付き)。在庫不足は 422 `insufficient_stock`(全明細分の `shortages`)で DB が変わらない。`operator` 欠落・不正な ID・アーカイブ済みは 422 `validation_failed`
- [x] ②③: 状態遷移と冪等(すでにその状態なら 200・履歴追加なし、それ以外は 409 `invalid_state`)。`operator` は受払履歴・オーダー履歴に残る。発送システム起源のオーダーを API から確定・解除できる
- [x] ⑤: `:id` で 200 / 404(存在しない・ID 形式不正)。`?external_slip_id=` で複数件(新しい順)・0 件(空配列で 200)。パラメータなしの一覧は 422
- [x] ⑥⑦: 有効なもののみ返す。⑦ は `item_code` で絞り込め、`maker_id`・`maker_name` を含む
- [x] 全エンドポイントで、エラー応答が共通形式(`error`・`message`・付加情報)。存在しないルートも JSON の 404。ボディの JSON が壊れていても 500 にしない
- [x] トークンの値が Logger 出力に含まれない
- [x] テスト: Controller(各エンドポイントの成功・各エラー)、`ServiceTokenAuth`、`FallbackController`/JSON の変換、同時 POST の冪等(500 にならない)。`make check` 相当(compile 警告ゼロ・format 差分なし・credo・test)が `food_vault` で通り、`food_ship` に影響しない

## スコープ外

- ④ 出庫取消(F-V7)・緊急操作(F-V8)・倉庫間移動(F-V9)は P1(段階 5)
- 発送側の `FoodShip.Inventory.Client`・環境変数(`INVENTORY_API_BASE_URL` など。段階 4)
- 本番の TLS 終端・`/api` の送信元制限(リバースプロキシ。architecture §16 #3 の本番構成が決まってから)
- レート制限・API バージョンの併存・OpenAPI 定義の生成
- **将来機能**: トークンのシステム発行と有効期限(DB で管理、管理画面から発行・失効、`last_used_at` の記録など)。今回は環境変数で運用者が用意した固定トークンのみ。将来の差し替えに備え、トークンの照合は `ServiceTokenAuth` 内の 1 関数に閉じ込め、Controller・Context には認証方式を持ち込まない(design.md で反映)
- 業務ロジック(引当・確定・解除・冪等)の変更。Context に不足があった場合のみ最小限の修正にとどめ、tasklist に記録する

## 決定事項

- 1 つのステアリングで段階 3 を扱い、作業単位(認証・基盤 → ①⑤ → ②③ → ⑥⑦)の順に実装し、単位ごとに品質ゲートを通してコミットする
- ステアリング文書は requirements → design → tasklist の順に 1 ファイルずつ承認を得る

## 未確定(design.md で決める)

- `ServiceTokenAuth` のトークン設定の置き場(`Application.get_env` のキー名)と、dev・test のデフォルト値
- Context 側で `id` から取得するときの `get_shipment_order!` と、ID 形式の事前検証・`{:error, :not_found}` の返し方
- `operator` の検証(欠落・空文字・255 文字超)を Controller で行うか、`Request` に寄せるか
- 壊れた JSON(`Plug.Parsers.ParseError`)や存在しないルートを共通形式にする方法(`ErrorJSON` の API 向け分岐、または `Plug.Exception`)
- 一覧系(⑥⑦)にページングを付けるか(§7.2 の応答はキー付き配列のみ。付けない前提)
