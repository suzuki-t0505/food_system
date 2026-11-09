# 設計: デフォルト倉庫

- 要求: [requirements.md](requirements.md)

## 方針

- 倉庫の指定は vault の `warehouses.is_default` に持つ。ship は引当のたびに在庫 API ⑥ を呼んでデフォルト倉庫の ID を得る(環境変数・キャッシュは持たない)
- 新しいエンドポイントは作らず、既存の `GET /api/v1/warehouses` の各倉庫に `is_default` を足す
- デフォルトは手動設定のみ。デフォルトが無い状態は正常な状態として扱い、ship は業務操作を拒否する

## 設計判断

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| デフォルトの持ち方 | `warehouses.is_default boolean not null default false` ＋ 部分ユニークインデックス(`where: "is_default"`) | 設定テーブルを新設せず、1 件以下を DB の制約で保証できる。同時に切り替えても片方が制約違反になる |
| 切り替え | `Repo.transact` で対象を `FOR UPDATE` → 現在のデフォルトを `false` → 対象を `true` | 部分ユニークインデックスがあるので、解除してから設定する順にする |
| アーカイブとの関係 | デフォルトはアーカイブ不可(`{:error, :default_warehouse}`)。アーカイブ済みはデフォルトにできない(`{:error, :archived}`) | アーカイブ済みの倉庫には在庫が入らず、引当が必ず失敗するため |
| 取得 API | ⑥ の応答に `is_default` を追加 | 既存クライアントは未知のキーを無視する。ship は `Enum.find(& &1["is_default"])` で取り出す |
| ship の取得タイミング | 引当・登録・数量変更の操作ごとに ⑥ を 1 回呼ぶ | 切り替えをすぐ反映できる。キャッシュの無効化を考えなくてよい |
| 画面の警告判定 | `warehouse_configured?/0` は ⑥ を**リトライなし**で呼ぶ。`:warehouse_not_configured` のときだけ警告、通信失敗は警告なし | 画面の表示のたびに呼ぶので、リトライ(1・2・4 秒)で表示を止めない。通信失敗を「未設定」と誤表示しない |
| 既存伝票 | 倉庫を切り替えても何もしない | 出庫確定・解除はオーダー ID で行うため倉庫に依存しない。再引当のときに新しい倉庫が使われる |

## 変更内容

### food_vault

| 対象 | 変更 |
| --- | --- |
| `priv/repo/migrations/20261108*_add_is_default_to_warehouses.exs`(新規) | `add :is_default, :boolean, null: false, default: false`、`create unique_index(:warehouses, [:is_default], where: "is_default", name: :warehouses_default_index)` |
| `Warehouses.Warehouse` | `field :is_default, :boolean, default: false`。`changeset/2` の `cast` には入れない。`default_changeset/1`(`true`)・`unset_default_changeset/1`(`false`)・`default?/1` を追加。`unique_constraint(:is_default, name: :warehouses_default_index)` |
| `Warehouses` | `get_default_warehouse/0`(アーカイブされていないデフォルト、無ければ `nil`)。`set_default_warehouse/2`(`authorize` → `Repo.transact`: 対象を `lock_warehouse/1` → アーカイブ済みなら `{:error, :archived}`、既にデフォルトなら `{:ok, warehouse}`、それ以外は他のデフォルトを解除して設定)。`do_archive/1` の `cond` に、デフォルトなら `{:error, :default_warehouse}` を先頭で返す節を追加(アーカイブ済みの判定より後) |
| `WarehouseLive.Index` | 状態列に「デフォルト」バッジ(`id="default-badge-#{id}"`)。admin に「デフォルトにする」ボタン(`id="set-default-#{id}"`、`phx-click="set_default"`。アーカイブ済み・既にデフォルトの行は出さない)。デフォルトの行はアーカイブボタンを出さない。`handle_event("set_default", ...)` を追加し、既存の `change/4` を使う(成功: 「デフォルト倉庫を設定しました。」、`{:error, :archived}`: 「アーカイブ済みの倉庫はデフォルトにできません。」、`{:error, :default_warehouse}`: 「デフォルト倉庫はアーカイブできません。別の倉庫をデフォルトにしてください。」) |
| `Api.V1.WarehouseJSON` | `is_default: warehouse.is_default` を追加 |
| `priv/repo/seeds.exs` | dev のみ。倉庫作成の直後、デフォルトが無ければ最初の倉庫を `set_default_warehouse/2` で設定する(本番のシードでは設定しない) |

### food_ship

| 対象 | 変更 |
| --- | --- |
| `Inventory.Client` | `warehouse_id/0` を削除。`default_warehouse_id(opts \\ [])` を追加: `request(:get, "/api/v1/warehouses", opts)` → `{:ok, 200, %{"warehouses" => list}}` から `is_default` の `id` を `{:ok, id}`、無ければ `{:error, :warehouse_not_configured}`、それ以外の応答は `{:error, :connection}`。`opts` に `retry: false` を渡せるようにし、`new/0` の `Keyword.merge` に乗せる。`@moduledoc` のエラー一覧に追記 |
| `ShippingSlips` | `ensure_warehouse/0` は `InventoryClient.default_warehouse_id/0` を返す(`{:ok, id}`、`{:error, :warehouse_not_configured}`、通信失敗は `{:error, :connection}` 等をそのまま返す)。`create_shipping_slip/2`・`update_shipping_slip/3` は `{:ok, _}` で進む。`allocate_shipping_slip/2` は ID を `allocate_remote/3` に渡す。`warehouse_configured?/0` は `default_warehouse_id(retry: false)` が `{:error, :warehouse_not_configured}` 以外なら `true` |
| `SlipMessages` | 未設定の文言は現状維持。通信失敗の戻り値(`{:error, :connection}` / `{:error, :unauthorized}`)が `create` / `update` の呼び出し側に新しく届くため、既存の `error_message/1` の節で表示できるか確認し、足りなければ追加する |
| `config/runtime.exs`・`config/test.exs` | `INVENTORY_WAREHOUSE_ID` の読み取り・`warehouse_id:`・関連コメントを削除 |
| `README.md`・`docker-compose.yml` | `INVENTORY_WAREHOUSE_ID` を削除し、「vault の倉庫画面でデフォルト倉庫を設定する」手順に置き換える |

### インフラ・ドキュメント

| 対象 | 変更 |
| --- | --- |
| `infra/terraform/variables.tf`・`apps.tf`・`terraform.tfvars.example`・`README.md` | `inventory_warehouse_id` と `INVENTORY_WAREHOUSE_ID` を削除。README の手順を「初期管理者でログイン → 倉庫を登録 → デフォルトにする」に変更 |
| `docs/architecture.md` | §11 の `INVENTORY_WAREHOUSE_ID` の行を削除。§16 の #6・#11 の記述を更新。在庫 API ⑥ の応答に `is_default` を追記 |
| `docs/functional-design.md` | 倉庫マスタ(デフォルト倉庫の設定・アーカイブ制約)、在庫 API ⑥、ルーティング(801 行付近)の記述を更新 |
| `docs/glossary.md` | 「デフォルト倉庫」を追加 |

## テスト

| 対象 | 内容 |
| --- | --- |
| `food_vault/test/food_vault/warehouses_test.exs` | `set_default_warehouse`: 設定、別の倉庫への切り替え(旧デフォルトが外れる)、既にデフォルトなら成功、アーカイブ済みは `:archived`、viewer・staff は `:forbidden`。`archive_warehouse`: デフォルトは `:default_warehouse`。`get_default_warehouse`: 無ければ `nil`。同時に 2 件を設定しても 1 件だけ(`concurrency_case`) |
| `.../live/warehouse_live/index_test.exs` | バッジ、ボタンの表示条件(admin のみ、アーカイブ済み・デフォルトの行は非表示)、設定の成功、アーカイブの拒否メッセージ |
| `.../controllers/api/v1/warehouse_controller_test.exs` | 応答の `is_default` |
| `food_ship/test/support/inventory_stub.ex` | `routes/1` は `GET /api/v1/warehouses` が `routes` に無ければデフォルト倉庫ありの応答(`is_default: true`、ID は `01JA0000000000000000000000`)で処理し、`calls/0` には含めない。`routes` に指定があればそちらを優先する。`warehouses/1`(応答の組み立て)を追加 |
| `.../shipping_slips_test.exs` | `without_warehouse/1` を、⑥ がデフォルト無しの応答を返す指定に置き換える。引当リクエストの `warehouse_id` がデフォルト倉庫の ID であること、取得で通信失敗したら保存・状態変更をしないこと |
| `.../live/shipping_slip_live/index_test.exs`・`form_test.exs` | 未設定で警告、通信失敗で警告なし |

## リスクと対策

| リスク | 対策 |
| --- | --- |
| ship の既存テストの多くが `routes` スタブを使い、⑥ の呼び出しで「想定外の在庫 API 呼び出し」になる | スタブ側で ⑥ を既定処理にする(上記)。`calls/0` に含めないので、既存の呼び出し順の検証は変えない |
| 引当のたびに ⑥ を呼ぶため、在庫停止時は登録の時点で失敗する | もともと引当で在庫 API が必要なため許容する。`pending` で保存せず、画面は通信エラーを表示する |
| 本番で既存の `INVENTORY_WAREHOUSE_ID` を使っていた環境は、デプロイ後にデフォルト未設定になる | デプロイ後に admin がデフォルトを設定する必要がある。README・terraform README に明記する(自動設定はしない方針) |
