# 設計: 基盤整備(段階 0)

要求は [requirements.md](requirements.md)。両アプリ(`food_vault` / `food_ship`)に**同じ構成**を置く(共有ライブラリは作らない)。以下 `{App}` は `FoodVault` / `FoodShip`、`{app}` は `food_vault` / `food_ship`。

## 1. 現状(調査結果)

- `lib/{app}/` には `application.ex` / `repo.ex` / `mailer.ex` のみ。`utils/`・`schema.ex` は無い
- `mix.exs` は両アプリで同形。`credo`・`ecto_ulid_next` は無い。`precommit` エイリアスは `compile --warnings-as-errors` / `deps.unlock --unused` / `format` / `test`
- `config/config.exs` の Logger は `$time $metadata[$level] $message` で `metadata: [:request_id]` のみ。`dev.exs` / `prod.exs` / `test.exs` はレベル指定のみ
- `config/test.exs` の DB ホスト名が `"db"` 固定(CI で使えない)
- `Plug.RequestId` はエンドポイントにある。`remote_ip` を Logger メタデータに入れる処理は無い
- `.github/` は無い。`Makefile` に `check` が無い。`.credo.exs` が無い

## 2. 方針

| 項目 | 決定 | 理由 |
| :-- | :-- | :-- |
| ULID | `ecto_ulid_next` を `mix.exs` に追加。`{App}.Schema` が `Ecto.ULID` を使う | requirements のとおり |
| ULID の検証 | 新規テーブルは作らない。テストで `CREATE TEMP TABLE`(サンドボックスのトランザクション内)を使い、`{App}.Schema` を使うテスト用スキーマの保存・取得・FK を確認する | 業務マイグレーションを増やさない。ロールバックで消える |
| JSON ログ | **自前のフォーマッタ**(`{App}.Utils.Logger.JSONFormatter`、`Jason` を使用)。新規依存は追加しない | `Jason` は既存依存。必要なのは数十行 |
| `remote_ip` | `Plug`(`{App}Web.Plugs.LoggerMetadata`)で `Logger.metadata(remote_ip: ...)` を設定し、`Plug.RequestId` の次に置く | `Plug.RequestId` は `request_id` だけを設定するため |
| Permission のロール | `%{role: :admin \| :staff \| :viewer}` を持つ任意の map / 構造体を受ける | `User` は段階 1 で作る。それまでマップでテストできる |
| CI | `setup-beam` で Elixir 1.20.5 / OTP 29 を入れ、ネイティブの `mix` で実行(PostgreSQL は service container) | `docker compose` + `npm` のビルドを CI で回すより速い。実行内容は `make check` と同じ 4 ステップ |

## 3. 変更するファイル

### 3.1 ULID・Schema(両アプリ)

- `mix.exs`: `{:ecto_ulid_next, "~> x.y"}` を追加(バージョンは `mix hex.info ecto_ulid_next` で確認して決める)
- `lib/{app}/schema.ex`(新規): coding-rules §5.1 のとおり。`use Ecto.Schema`、`@primary_key {:id, Ecto.ULID, autogenerate: true}`、`@foreign_key_type Ecto.ULID`
- `config/config.exs`: `generators` の `binary_id: true` は**残す**(architecture §4)
- 最初にやること: 依存を追加して `mix deps.get && mix compile --warnings-as-errors` と下記テストを通す。**通らなければ中断して報告**する(requirements のとおり自前実装に切り替えない)

### 3.2 Logger(両アプリ)

`lib/{app}/utils/logger.ex`(新規)

- `@categories`(atom → 表示名): `log_in` / `create` / `update` / `delete` / `batch` / `api` / `other`。`api` は在庫 API 呼び出し用(段階 3 以降)。増やすときはここに足す
- `use {App}.Utils.Logger` で `require {App}.Utils.Logger, as: Logger` を展開する(coding-rules §12.1)
- マクロ `info/3` / `warning/3` / `error/3`(`message, category, variables`)。カテゴリが**リテラルで定義済み**なら、`Elixir.Logger` を呼ぶコードに展開する。`variables` は `normalize/1` を通す
- 未定義カテゴリ: ログは出し、`config :{app}, {App}.Utils.Logger, raise_on_unknown_category: true`(`dev` / `test`)のとき `raise ArgumentError`。`prod` は `false`。設定は呼び出し時に `Application.get_env/3` で読む(coding-rules §13.3)。コンパイル時に落とさない(落とすとテストで未定義カテゴリを検証できない)
- `category_name!/1`(公開関数): 上の判定を関数として提供する。マクロを使えない `OperationLog` から呼ぶ
- `normalize/1`(公開関数。architecture §12 の自動マスク):
  - Ecto スキーマ構造体: `__meta__`、`__schema__(:redact_fields)`、仮想フィールド、`%Ecto.Association.NotLoaded{}` を除外してマップ化
  - マップ: `@redact_keys`(`:token` / `:password` / `:hashed_password` / `:current_password` / `:encode_password`、文字列キーも)を除外
  - リスト・タプルは再帰、それ以外(日時など)はそのまま
- 出力は `Logger.info(%{message:, category:, variable:})` のレポート形式(coding-rules のサンプルと同形)

`lib/{app}/utils/logger/json_formatter.ex`(新規)

- Erlang `:logger` のフォーマッタ(`format/2` と `check_config/1`)。1 行 1 JSON: `time` / `level` / `message` / `category` / `variable` / `request_id` / `remote_ip` / `mfa` / `file` / `line`
- JSON にできない値(PID、タプルなど)は `inspect/1` で文字列にする
- `config/prod.exs`: `config :logger, :default_handler, formatter: {{App}.Utils.Logger.JSONFormatter, metadata: [:request_id, :remote_ip, :mfa, :file, :line]}`。`dev` / `test` は現行の形式のまま
- 注意: `mfa` / `file` / `line` は Elixir の Logger が自動で付ける。`OperationLog` 経由のログは、位置が `OperationLog` になる

`lib/{app}_web/plugs/logger_metadata.ex`(新規)と `lib/{app}_web/endpoint.ex`

- `conn.remote_ip` を文字列にして `Logger.metadata(remote_ip: ...)` に設定する。`Plug.RequestId` の直後に `plug` を追加する
- リバースプロキシ配下の送信元 IP(`X-Forwarded-For`)は、本番構成(未決事項 #3)が決まるまで扱わない

### 3.3 OperationLog(両アプリ)

`lib/{app}/utils/operation_log.ex`(新規)

- `info(socket_or_conn, message, category, data)`、`category` は `:create` / `:update` / `:delete` のみ(ガード)
- 「誰が」: `assigns[:current_scope]` の `user`(`id` と `email` 等は出さず `id` のみ)。認証前は `nil`(`"未認証"`)。`current_scope` は段階 1 で作るため、ここでは `assigns` から**ある場合だけ**取り出す
- 「どのページで」: LiveView は `socket.view` と `socket.assigns[:live_action]`、Controller は `conn.request_path`
- 「どのデータで」: 第 4 引数を `Logger.normalize/1` に通す(呼び出し側で選別しない)
- 「いつ」は Logger のタイムスタンプ。出力は `Logger.category_name!/1` を使って `Elixir.Logger` を呼ぶ
- `use {AppWeb}, :live_view` / `:controller` への組み込みは**段階 1 以降**(`current_scope` が揃ってから)。今回は単体で呼べる状態までにする

### 3.4 Permission(両アプリ)

`lib/{app}/utils/permission.ex`(新規)

- `role_at_least?(user, role)`: 順位 `viewer < staff < admin` で判定する公開関数
- `can?(user, action)`: `@required_roles`(action → 最低ロール)を引いて `role_at_least?/2` を呼ぶ。**未定義の action は `false`**(拒否が既定)。`user` が `nil` やロール無しなら `false`
- `food_vault` の `@required_roles`: `emergency_ship_order: :admin`(architecture §8.3 の緊急操作)。`food_ship` は空で始める。個別の権限表は段階 1 以降に足す

### 3.5 品質ゲート(両アプリ + ルート)

- `mix.exs`: `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` を追加。`precommit` に `credo --all` を足し、`compile --warnings-as-errors` → `deps.unlock --unused` → `format` → `credo --all` → `test` の順にする
- `.credo.exs`: `mix credo gen.config` で生成。生成物(`core_components.ex` 等)で指摘が出る場合は、**自作コードを直し**、生成物は `files.excluded` に足す(基準を緩めて指摘を消すことはしない)
- `Makefile`: `check: mix_compile mix_format mix_credo mix_test` を追加し、`.PHONY` に足す。CI 用には `format --check-formatted` を使う(ローカルの `mix_format` は整形する)
- `config/test.exs`: DB の `hostname` を `System.get_env("PGHOST", "db")` にする(両アプリ)。コンテナ内は従来どおり `db`

### 3.6 CI

`.github/workflows/ci.yml`(新規)

- トリガー: `pull_request` のみ
- マトリクス: `app: [food_vault, food_ship]`、`working-directory: ${{ matrix.app }}`
- service: `postgres:15.2`(`POSTGRES_PASSWORD=postgres`)、`PGHOST=localhost`
- ステップ: `actions/checkout` → `erlef/setup-beam`(Elixir 1.20.5 / OTP 29) → `deps` と `_build` のキャッシュ → `mix deps.get` → `mix compile --warnings-as-errors --force` → `mix format --check-formatted` → `mix credo --all` → `mix test`
- 書き込み権限は `contents: read` のみ

## 4. テスト(両アプリ)

| ファイル | 内容 |
| :-- | :-- |
| `test/{app}/schema_test.exs` | `CREATE TEMP TABLE` で親子 2 表を作り、`use {App}.Schema` のテスト用スキーマで ULID の主キー・FK を保存・取得。ID が 26 文字の文字列、`dump` で 16 バイト、不正値は `cast` が `:error` |
| `test/{app}/utils/logger_test.exs` | 定義済みカテゴリで `capture_log` に出力される。未定義カテゴリで `ArgumentError`(`raise_on_unknown_category: true`)。`normalize/1` が `password` / `token`(atom・文字列キー)、`redact: true` のフィールド、`__meta__`、未ロードのアソシエーションを除外する |
| `test/{app}/utils/logger/json_formatter_test.exs` | `format/2` の出力が 1 行の JSON で、`request_id` / `remote_ip` / `mfa` / `file` / `line` を含む。PID など JSON 化できない値で落ちない |
| `test/{app}/utils/operation_log_test.exs` | `Phoenix.LiveView.Socket` / `Plug.Conn` から操作者・ページを取り出す。`:create` 以外のカテゴリは `FunctionClauseError`。認証前(`current_scope` 無し)でも落ちない |
| `test/{app}/utils/permission_test.exs` | `admin` ⊃ `staff` ⊃ `viewer`。未定義 action は `false`、`nil` は `false`。`food_vault` は `:emergency_ship_order` が `admin` のみ |
| `test/{app}_web/plugs/logger_metadata_test.exs` | `remote_ip` が `Logger.metadata/0` に入る |

「本番設定のログが JSON」は、`config/prod.exs` の設定値を `Config.Reader` で読んで `formatter` を確認するテスト、または手動確認(`MIX_ENV=prod` でフォーマッタの `format/2` を呼ぶ)で担保する。

## 5. 実施順(詳細は tasklist.md)

1. 依存追加(`ecto_ulid_next`)と互換性の確認 ← **ここで失敗したら中断**
2. `Schema` → `Logger`(+ `normalize`)→ JSON フォーマッタ → Plug → `OperationLog` → `Permission`(各テストと一緒に)
3. `credo` 導入、`.credo.exs`、`Makefile` の `check`、`precommit`
4. `config/test.exs` の `PGHOST`、CI ワークフロー
5. 両アプリで `make check`
6. 永続ドキュメントの更新(`ecto_ulid` → `ecto_ulid_next`、`check` の「整備予定」表記、未決事項 #1・#5 の解消)

## 6. 影響範囲・リスク

- 業務テーブル・マイグレーション・画面は変更しない。既存テスト(各 5 件)は影響を受けない
- `ecto_ulid_next` が Elixir 1.20 で動かない場合は、手順 1 で止まる(未決事項 #1)
- `credo --all` が既存の雛形コードで指摘を出す可能性がある。生成物の除外範囲は実装時に決める
- `remote_ip` はリバースプロキシ配下では proxy の IP になる。本番構成の決定(#3)後に見直す
- CI の Elixir 1.20.5 / OTP 29 が `setup-beam` で取得できない場合は、`Dockerfile.dev` の ARG と同じバージョンを確認して合わせる。最終確認は PR を出して CI を実際に走らせるまでできない
