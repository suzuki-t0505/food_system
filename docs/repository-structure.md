# リポジトリ構造定義書 (Repository Structure)

- 対象: `suzuki-t0505/food_system`（1 リポジトリに 2 つの Phoenix アプリを置くモノレポ）
- 位置づけ: ファイル・ディレクトリを「どこに・どう命名して置くか」を定める。技術の選定は [architecture.md](architecture.md)、機能は [functional-design.md](functional-design.md)、規約は [coding-rules.md](coding-rules.md) に従う
- 表記: **［現状］** は実リポジトリに存在するもの、**［計画］** は実装で作成するもの。計画のファイル名は規約にもとづく案で、細部は各作業の `.steering/design.md` で確定する

---

## 1. リポジトリ全体

```
food_system/
├── CLAUDE.md                  # プロジェクトメモリ（開発プロセスと技術スタック）［現状］
├── Makefile                   # 開発コマンド（コンテナ経由）［現状］
├── Dockerfile.dev             # 開発用イメージ（両アプリ共用）［現状］
├── docker-compose.yml         # food_vault_web / food_ship_web / db / pgadmin4 ［現状］
├── skills-lock.json           # スキルのロック情報［現状］
├── docs/                      # 永続ドキュメント［現状］
├── .steering/                 # 作業単位のドキュメント（作業ごとに作成）［計画］
├── mock/                      # HTML モック（create-mock スキルの出力）［計画］
├── food_vault/                # 在庫管理システム（Phoenix アプリ）［現状：雛形］
├── food_ship/                 # 発送システム（Phoenix アプリ）［現状：雛形］
├── infra/terraform/           # GCP 基盤の Terraform（§1.2）［現状］
├── .claude/                   # Claude Code の設定・エージェント・スキル［現状］
└── .agents/skills/            # security-audit スキル［現状］
```

### 1.1 モノレポの原則

| 原則 | 内容 |
| :-- | :-- |
| 2 アプリは完全に独立 | `food_vault` と `food_ship` は別 Mix プロジェクト・別 DB・別コンテナ。**一方のコードを他方から `import` / `alias` / 依存に追加しない**（連携は HTTP API のみ） |
| 共有コードは作らない | 共通化したくなっても、共有ライブラリ（umbrella・path 依存）は作らない。`{App}.Schema`・`Permission`・`Logger`・認証などの同形のモジュールは **各アプリにそれぞれ置く**（コピーを許容し、変更は両方に反映する） |
| ルートに置くもの | プロジェクト全体で共有するもの（`docker-compose.yml`・`Makefile`・`Dockerfile.dev`・`docs/`・`CLAUDE.md`）だけ。アプリ固有の設定は各アプリ配下に置く |
| コマンドはコンテナ経由 | ホストで直接 `mix` を叩かない（`docker compose run --rm food_vault_web mix ...`）。`Makefile` に集約する |

### 1.2 GCP 基盤 `infra/terraform/`

```
infra/terraform/
├── README.md                  # 初回構築・デプロイ・検証の手順
├── versions.tf                # Terraform / プロバイダのバージョン、backend "gcs"（部分設定）
├── .terraform.lock.hcl        # プロバイダのロック（コミットする）
├── variables.tf / outputs.tf
├── backend.hcl.example / terraform.tfvars.example   # 実値の backend.hcl / terraform.tfvars はコミットしない
├── apis.tf / registry.tf / network.tf / sql.tf / secrets.tf   # 共有基盤（API・Artifact Registry・VPC・Cloud SQL・共有の秘密）
├── apps.tf                    # module "food_vault" / "food_ship" の呼び出し
├── lb.tf / armor.tf           # 外部アプリケーション LB・Cloud Armor
├── modules/app/               # 1 アプリ分（DB・DB ユーザー・秘密・SA・Cloud Run サービス・Cloud Run Job）
└── tests/plan.tftest.hcl      # terraform test（モックプロバイダで plan を評価）
```

- 2 アプリで同じ形のリソースは `modules/app` に置き、差分（環境変数・秘密・egress）は引数で渡す。ファイルは役割ごとに分ける

---

## 2. ドキュメント（`docs/` と関連ディレクトリ）

```
docs/
├── product-requirements.md    # プロダクト要求定義書（何を作るか）
├── functional-design.md       # 機能設計書（機能・データ・処理・画面・API）
├── architecture.md            # 技術仕様書（技術選定・実装方針）
├── repository-structure.md    # 本書
├── development-guidelines.md  # 開発ガイドライン
├── glossary.md                # ユビキタス言語定義
├── coding-rules.md            # コーディング規約（[必須] / [推奨] 付き）
└── ideas/                     # 下書き・アイデア・批判的レビュー
    ├── 食品在庫管理システム設計.md
    ├── 食品在庫管理システム設計-critical-review.md
    ├── 発送システム 基本設計書.md
    └── 発送システム 基本設計書-critical-review.md
```

| 種別 | 置き場所 | 内容 | 更新頻度 |
| :-- | :-- | :-- | :-- |
| 永続ドキュメント | `docs/*.md` | 「何を作るか」「どう作るか」の基本設計。プロジェクト全体の北極星 | 低い。変更は承認を得て行う |
| 下書き・アイデア | `docs/ideas/` | 壁打ち・設計ドラフト・批判的分析レポート。自由形式 | 履歴として残す（正式版へ昇格後も削除しない） |
| 作業単位のドキュメント | `.steering/{YYYYMMDD}-{タスク名}/` | 「今回何をするか」。`requirements.md` / `design.md` / `tasklist.md` | 作業ごとに新規作成し、履歴として保持 |
| HTML モック | `mock/{YYYYMMDD}/` | クライアント向け UI イメージ（`create-mock` スキル） | 作業ごと |

- **命名**: 永続ドキュメントは英語のケバブケース（`product-requirements.md`）。`docs/ideas/` は日本語名可（批判的レビューは対象ファイル名の末尾に `-critical-review` を付ける）。`.steering/` は `20250115-add-user-profile` 形式（日付 8 桁 ＋ 英小文字ケバブケース）。
- **ドキュメントは 1 ファイルずつ作成し、承認を得てから次に進む**（CLAUDE.md）。永続ドキュメントを更新するときは、関連する `docs/ideas/` の元ドラフトとの食い違いを残さない。
- `docs/ideas/` のドラフトから直接実装に進まない。永続ドキュメント → `.steering/` → 実装の順（CLAUDE.md の基本フロー）。

---

## 3. 在庫管理システム `food_vault/`

### 3.1 トップレベル

```
food_vault/
├── .formatter.exs             # import_deps と HEEx フォーマッタ［現状］
├── .gitignore                 # ［現状］
├── AGENTS.md                  # Phoenix 1.8 / LiveView 等の AI 向けガイド（current_scope の扱いを含む）［現状］
├── README.md                  # ［現状］
├── mix.exs / mix.lock         # 依存・エイリアス（setup / test / precommit など）［現状］
├── Dockerfile / .dockerignore # 本番イメージ（`mix phx.gen.release --docker` で生成）［現状］
├── rel/overlays/bin/          # リリースの起動スクリプト server / migrate（`mix phx.gen.release` で生成）［現状］
├── assets/                    # JS / CSS / vendor（Tailwind・daisyUI・heroicons）［現状］
├── config/                    # config / dev / prod / runtime / test ［現状］
├── lib/                       # アプリ本体（§3.2）
├── priv/                      # マイグレーション・seeds・static・gettext
└── test/                      # lib のミラー（§3.4）
```

### 3.2 `lib/`（ドメイン層 ＋ Web 層）

```
lib/
├── food_vault.ex                       # ［現状］
├── food_vault/
│   ├── application.ex / repo.ex / mailer.ex   # ［現状］
│   ├── schema.ex                       # {App}.Schema マクロ（ULID 主キー）
│   ├── accounts.ex                     # Context: ユーザー・認証・ロール
│   ├── accounts/
│   │   ├── user.ex
│   │   ├── user_token.ex
│   │   └── scope.ex                    # current_scope（user を持つ）
│   ├── release.ex                      # リリースタスク（migrate / rollback / migrate_and_seed / 初期管理者の作成）
│   ├── makers.ex  /  makers/maker.ex                    # ［現状：段階 2 で実装済み］
│   ├── warehouses.ex  /  warehouses/warehouse.ex        # ［現状：段階 2］
│   ├── items.ex  /  items/item.ex                       # ［現状：段階 2］
│   ├── inventories.ex                  # Context: 入荷・調整、ロットのロックと更新、受払履歴の記録・検索［現状：段階 2。移動は P1］
│   ├── inventories/
│   │   ├── inventory_lot.ex            # ［現状：段階 2］
│   │   └── inventory_transaction.ex    # 追記専用 ［現状：段階 2］
│   ├── shipment_orders.ex              # Context: 引当・確定・解除［現状：段階 2。出庫取消は P1］
│   ├── shipment_orders/
│   │   ├── shipment_order.ex / shipment_order_line.ex / shipment_allocation.ex   # ［現状：段階 2］
│   │   ├── shipment_order_event.ex     # 追記専用 ［現状：段階 2］
│   │   ├── request.ex                  # 引当要求の検証・正規化・冪等判定の比較 ［現状：段階 2］
│   │   └── allocation_plan.ex          # 明細 1 行の引当計画（純粋関数）［現状：段階 2］
│   └── utils/
│       ├── calc.ex                     # 総バラ数などの計算 ［現状：段階 2］
│       ├── permission.ex               # Permission.can?/2・authorize/2
│       ├── logger.ex                   # カテゴリ付き Logger ラッパー（normalize/1 で機微データをマスク）
│       ├── logger/json_formatter.ex    # 本番用 JSON ログフォーマッタ
│       ├── operation_log.ex            # 操作ログ
│       └── convert_datetime.ex         # UTC → JST 変換 ［現状：段階 2］
└── food_vault_web/
    ├── endpoint.ex / router.ex / telemetry.ex / gettext.ex   # ［現状］
    ├── user_auth.ex                    # plug と on_mount（current_scope の assign）［現状：段階 1 で実装済み］
    ├── components/
    │   ├── core_components.ex          # **改変しない** ［現状］
    │   ├── layouts.ex  /  layouts/root.html.heex   # ［現状］
    │   └── inventory_components.ex     # ページ送り・アーカイブ表示・数量 3 列表記 ［現状：段階 2］
    ├── controllers/
    │   └── error_html.ex / error_json.ex / page_*.ex   # error_json.ex は在庫 API の共通エラー形式 ［現状］
    ├── api/                            # 在庫 API（JSON。LiveView 対象外）［現状：段階 3］
    │   ├── error_response.ex           # 共通エラー形式の本文（plug・FallbackController・ErrorJSON が使う）
    │   ├── operator.ex                 # operator / reason の検証
    │   ├── fallback_controller.ex      # Context の戻り値 → 共通エラー形式
    │   └── v1/
    │       ├── shipment_order_controller.ex  / shipment_order_json.ex   # ①②③⑤
    │       ├── warehouse_controller.ex       / warehouse_json.ex        # ⑥
    │       └── item_controller.ex            / item_json.ex             # ⑦
    ├── plugs/
    │   ├── logger_metadata.ex          # Logger メタデータに remote_ip を設定
    │   └── service_token_auth.ex       # サービストークン認証（定数時間比較）［現状：段階 3］
    └── live/
        ├── user_session_live/          # ログイン・パスワード変更（login.ex / password.ex）［現状］
        ├── inventory_lot_live/         # 在庫一覧・ロット詳細（index.ex / show.ex）［現状：段階 2］
        ├── inventory_receipt_live/     # 入荷登録（form.ex）［現状：段階 2］
        ├── shipment_order_live/        # 出庫オーダー（index.ex / show.ex / form.ex）［現状：段階 2］
        ├── inventory_transfer_live/    # 倉庫間移動（form.ex）［計画：P1］
        ├── inventory_transaction_live/ # 受払履歴（index.ex）［現状：段階 2］
        ├── maker_live/ warehouse_live/ item_live/   # マスタ一覧・参照（全ロール）。/masters/... ［現状：段階 2］
        └── management/                 # admin 専用（/management/...）
            ├── inventory_adjustment_live/    # 棚卸調整・入荷訂正・荷まとめ ［現状：段階 2］
            ├── maker_live/ warehouse_live/ item_live/   # マスタの登録・編集（form.ex）［現状：段階 2］
            └── user_live/              # ユーザー管理（index.ex / form.ex）［現状］
```

### 3.3 `priv/`

```
priv/
├── repo/
│   ├── migrations/             # {timestamp}_{動詞_対象}.exs（FK の依存順に作成）
│   └── seeds.exs               # 開発用の初期データ（初期管理者、メーカー 2・倉庫 2・商品 3）［現状：作成済み・冪等］
├── static/                     # ビルド成果物（git 管理外）
└── gettext/                    # ［現状］。単一言語のため業務文言には使わない
```

マイグレーションの作成順（FK の依存順。**［現状：段階 2 で 4〜6 を実装済み。実際の順は下表の備考のとおり**）:

| 順 | マイグレーション | 内容 |
| :-- | :-- | :-- |
| 1 | `create_users_auth_tables` | `citext` 拡張、`users`、`users_tokens` |
| 2 | `create_makers_and_warehouses` | マスタ |
| 3 | `create_items` | `makers` を参照 |
| 4 | `create_inventory_lots` | CHECK 制約・複合ユニーク |
| 5 | `create_inventory_transactions` | `inventory_lots` / `users` を参照。追記専用トリガー関数 `forbid_update_delete()` とトリガーを作る。`shipment_order_id` は FK なしで作る |
| 6 | `create_shipment_orders` | `shipment_orders` / `shipment_order_lines` / `shipment_allocations` / `shipment_order_events`、部分ユニーク、`shipment_order_events` の追記専用トリガー、`inventory_transactions.shipment_order_id` への FK 追加（5 の時点では `shipment_orders` が無いため） |

### 3.4 `test/`

```
test/
├── test_helper.exs
├── support/
│   ├── data_case.ex / conn_case.ex          # ［現状］
│   ├── concurrency_case.ex                  # 複数プロセスで実コミットする並行テスト用（`sandbox: false`、後始末は TRUNCATE）［現状：段階 2］
│   └── fixtures/*_fixtures.ex               # Context の公開 API 経由で作る（masters / inventories / shipment_orders）
├── food_vault/                              # ドメイン層（lib/food_vault をミラー）
│   ├── accounts_test.exs / inventories_test.exs / shipment_orders_test.exs / ...
│   └── utils/
└── food_vault_web/
    ├── controllers/api/v1/*_test.exs        # API（認証・冪等性・エラー形式）
    ├── plugs/service_token_auth_test.exs
    └── live/*_live_test.exs                 # 画面と DB の両方を検証
```

---

## 4. 発送システム `food_ship/`

トップレベル（`.formatter.exs`・`AGENTS.md`・`assets/`・`config/`・`mix.exs` など）は `food_vault/` と同じ構成。

### 4.1 `lib/`

```
lib/
├── food_ship/
│   ├── application.ex / repo.ex / mailer.ex   # ［現状］
│   ├── schema.ex                       # {App}.Schema マクロ（ULID 主キー）
│   ├── accounts.ex  /  accounts/{user,user_token,scope}.ex
│   ├── release.ex                      # リリースタスク（migrate / rollback / migrate_and_seed / 初期管理者の作成）
│   ├── clients.ex  /  clients/client.ex
│   ├── shipping_items.ex  /  shipping_items/shipping_item.ex
│   ├── expiration_rules.ex  /  expiration_rules/expiration_rule.ex
│   ├── shipping_slips.ex               # Context: 登録・引当・再引当・梱包・取消・CSV 取込
│   ├── shipping_slips/
│   │   ├── shipping_slip.ex
│   │   ├── slip_allocated_lot.ex
│   │   └── csv_import.ex               # CSV の検証・パース（Schema ではない補助モジュール）
│   ├── total_picks.ex                  # Context: 作成・再発行・取消・集計クエリ
│   ├── total_picks/total_pick.ex
│   ├── inventory/
│   │   └── client.ex                   # 在庫 API クライアント（Req）。外部 I/O 境界
│   └── utils/
│       ├── permission.ex / logger.ex / operation_log.ex / convert_datetime.ex
│       ├── calc.ex                     # 箱数・出庫総数量・最低許容期限日などの計算
│       └── pdf.ex                      # PDF 生成（ChromicPDF）の境界
└── food_ship_web/
    ├── endpoint.ex / router.ex / telemetry.ex / gettext.ex   # ［現状］
    ├── user_auth.ex                    # ［現状：段階 1 で実装済み］
    ├── plugs/logger_metadata.ex        # Logger メタデータに remote_ip を設定
    ├── components/                     # core_components.ex は改変しない
    ├── controllers/
    │   ├── report_controller.ex        # total_pick/2・work_order/2・total_pick_bundle/2
    │   ├── report_html.ex  /  report_html/*.heex   # 帳票テンプレート（A4 縦）
    │   └── error_*.ex / page_*.ex      # ［現状］
    └── live/
        ├── user_session_live/          # ログイン・パスワード変更［現状］
        ├── shipping_slip_live/         # 出荷日別の作業画面（index.ex）／伝票登録（form.ex）／CSV 取込
        ├── total_pick_live/            # 一覧・詳細（index.ex / show.ex）
        └── management/                 # admin 専用
            ├── client_live/ shipping_item_live/ expiration_rule_live/
            └── user_live/              # ユーザー管理（index.ex / form.ex）［現状］
```

### 4.2 `priv/repo/migrations/`（作成順）

| 順 | マイグレーション | 内容 |
| :-- | :-- | :-- |
| 1 | `create_users_auth_tables` | `citext` 拡張、`users`、`users_tokens` |
| 2 | `create_clients` / `create_shipping_items` / `create_expiration_rules` | マスタ |
| 3 | `create_total_picks` | `pick_no` のシーケンス |
| 4 | `create_shipping_slips` | `slip_no` のシーケンス、CHECK 制約、部分ユニーク、`total_picks` への FK |
| 5 | `create_slip_allocated_lots` | 表示用キャッシュ |

### 4.3 `test/`

在庫側と同じミラー構成。加えて次を置く。

```
test/
├── food_ship/
│   ├── inventory/client_test.exs        # Req.Test のスタブで応答別に検証
│   ├── shipping_slips_test.exs / total_picks_test.exs / ...
│   └── shipping_slips/csv_import_test.exs
└── food_ship_web/controllers/report_controller_test.exs   # Utils.Pdf のみモック
```

---

## 5. 命名と配置の規則

| 種別 | 規則 | 例 |
| :-- | :-- | :-- |
| Context | `snake_case.ex`（複数形）。Context ファイルとディレクトリは同名 | `shipment_orders.ex` ／ `shipment_orders/` |
| Ecto スキーマ | `snake_case.ex`（**単数形**）。`use {App}.Schema` | `shipment_orders/shipment_order.ex` |
| LiveView | ディレクトリ `{resource}_live/` に `index.ex` / `show.ex` / `form.ex`。ロール別に UI が分かれる場合はサブディレクトリ | `shipment_order_live/index.ex` |
| コンポーネント | `*_components.ex` | `card_components.ex` |
| Controller（JSON API） | `FoodVaultWeb.Api.V1.*Controller`、レスポンスは `*_json.ex` | `api/v1/shipment_order_controller.ex` |
| Plug | `plugs/*.ex`（モジュール plug） | `plugs/service_token_auth.ex` |
| Utils | `utils/`。状態を持たない関数モジュール | `utils/permission.ex` |
| マイグレーション | `{timestamp}_{動詞_対象}.exs` | `20260115053602_create_inventory_lots.exs` |
| テスト | `lib` をミラー。`*_test.exs`。フィクスチャは `support/fixtures/*_fixtures.ex` | `inventory_lots_test.exs` |
| 外部 I/O 境界 | 発送の `inventory/client.ex` と `utils/pdf.ex`。テストでモックしてよいのはここだけ | — |

- **Web 層は Context の公開 API だけを呼ぶ**。`lib/{app}_web/` に `Repo` やスキーマへのクエリを書かない。
- **`core_components.ex` は改変しない**。業務用のコンポーネントは `*_components.ex` として別ファイルに作る。
- **子エンティティ専用の Context は作らない**（例：`ShipmentOrderLine` 専用の Context は作らず `ShipmentOrders` に置く）。
- 認可は `Permission.can?/2` に一本化する。ルート（`router.ex`）の `live_session` には、plug と同じ強さの `on_mount` を必ず指定する。
- 認証系ルートは `/users/log_in` 等、`admin` 専用画面は `/management/...`、参照・業務画面は `/inventory_lots` 等の一般パス。

---

## 6. 設定・ビルド成果物・Git 管理

| 対象 | 置き場所 | 管理 |
| :-- | :-- | :-- |
| アプリの設定 | `food_*/config/*.exs`。秘密情報は `runtime.exs` のみ | Git 管理（秘密情報の値は置かない） |
| 環境変数 | Compose の `environment`（開発）／本番は実行環境の変数 | 値は Git 管理外 |
| 依存・ビルド | `food_*/deps/`・`_build/`・`priv/static/`・`assets/node_modules/` | Git 管理外（各アプリの `.gitignore`） |
| ロックファイル | `mix.lock`・`assets/package-lock.json` | Git 管理 |
| DB データ | Docker ボリューム `dbdata` | Git 管理外 |
| 生成した PDF | 保存しない（帳票は都度生成） | — |

### 6.1 現状の整備事項

| # | 内容 |
| :-- | :-- |
| 1 | `mock/` はまだ無い。作業の開始時に作成する(`.steering/`、`Makefile` の `check`、`credo`、PR ワークフローは整備済み。[architecture.md §14](architecture.md#14-開発環境品質ゲートci)) |

### 6.2 ルートの `.gitignore` の方針

ルートに `.gitignore` を置き、次を除外する。アプリ固有の除外（`_build/`・`deps/`・`priv/static/` など）は各アプリの `.gitignore` に書く。

| 対象 | 扱い | 理由 |
| :-- | :-- | :-- |
| `.env` / `.env.*`（`.env.example` は除く） | 除外 | 秘密情報の値をコミットしない |
| `.claude/scheduled_tasks.lock` | 除外（追跡も解除） | セッション ID・PID を含む実行時の状態で、共有する意味がない |
| `claude_code_session_logs/` | 除外 | セッションログ（`.claude/settings.local.json` の読み取り禁止対象） |
| `.elixir_ls/`・`.vscode/`・`.idea/`・OS やエディタの一時ファイル | 除外 | 個人の環境 |
| **`.claude/settings.local.json`** | **除外しない（Git 管理を続ける）** | `.env` や `deps/` などの読み取り禁止（`deny`）を全員に適用する共有設定として、プロジェクトセットアップ時から管理している。名前に `local` を含むが、個人の設定ではない。個人用の許可（`allow`）を足したくなったら、このファイルではなく個人のユーザー設定（`~/.claude/settings.json`）に書く |

---

## 7. 変更時のチェック

新しいファイルを追加するときは、次を確認する。

- [ ] 規則（§5）どおりの場所・名前か。既存の類似ファイルを Grep で探して、パターンに合わせたか
- [ ] 2 アプリ間で `alias` / `import` / 依存追加をしていないか（連携は HTTP API のみ）
- [ ] 新しい Context / スキーマを追加したら、`architecture.md §3.2` の Context 一覧と本書 §3.2・§4.1 を更新したか
- [ ] 新しい用語を追加したら、`glossary.md` に定義したか
- [ ] マイグレーションに FK の索引と、`create table` の外の `create index` を書いたか
- [ ] 永続ドキュメントを変えたら、`docs/ideas/` のドラフトとの食い違いを残していないか
