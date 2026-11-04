# タスクリスト: 基盤整備(段階 0)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。`{app}` は `food_vault` / `food_ship` の**両方**に同じ作業をする。コマンドはコンテナ経由(`make` または `docker compose run --rm {app}_web mix ...`)。進捗に合わせてチェックを更新する。

## 1. ULID 依存の確認(失敗したら中断して報告)

- [x] `mix hex.info ecto_ulid_next` で最新版と Elixir / Ecto 要件を確認する
- [x] 両アプリの `mix.exs` に `ecto_ulid_next` を追加し、`mix deps.get`
- [x] `mix compile --warnings-as-errors` が通る(`Ecto.ULID` が使える)
- [x] 通らない場合: 作業を止め、エラーの要点を報告して判断を仰ぐ(該当なし。`ecto_ulid_next` 1.0.2 は Elixir 1.20 で警告なくコンパイルできた)

## 2. Schema と ULID テスト

- [x] `lib/{app}/schema.ex` を作る(`Ecto.ULID` の主キー・外部キー)
- [x] `test/{app}/schema_test.exs`: `CREATE TEMP TABLE` の親子 2 表で保存・取得・FK、ID 26 文字、`dump` 16 バイト、不正値の `cast` が `:error`
- [x] テストが通る

## 3. Logger

- [x] `lib/{app}/utils/logger.ex`: `@categories`、`use`、`info` / `warning` / `error` マクロ、`category_name!/1`、`normalize/1`
- [x] `config/{dev,test,prod}.exs`: `raise_on_unknown_category`(dev・test は `true`、prod は `false`)
- [x] `test/{app}/utils/logger_test.exs`: 定義済みカテゴリの出力、未定義カテゴリで `ArgumentError`、`normalize/1` のマスク(`password` / `token`、`redact: true`、`__meta__`、未ロードのアソシエーション)
- [x] テストが通る

## 4. JSON ログと `remote_ip`

- [x] `lib/{app}/utils/logger/json_formatter.ex`: `format/2` と `check_config/1`
- [x] `config/prod.exs`: `:default_handler` に JSON フォーマッタとメタデータ(`request_id` / `remote_ip` / `mfa` / `file` / `line`)を設定
- [x] `lib/{app}_web/plugs/logger_metadata.ex` を作り、`endpoint.ex` の `Plug.RequestId` の直後に追加
- [x] `test/{app}/utils/logger/json_formatter_test.exs`(1 行の JSON、各メタデータ、PID などで落ちない)
- [x] `test/{app}_web/plugs/logger_metadata_test.exs`
- [x] `MIX_ENV=prod` 設定でフォーマッタの出力を手動確認する(`config/prod.exs` の設定値も確認。`prod.exs` を読み込み、実際に JSON が出ることを確認済み)
- [x] テストが通る

## 5. OperationLog

- [x] `lib/{app}/utils/operation_log.ex`: `info/4`(`:create` / `:update` / `:delete` のみ)、操作者・ページの取り出し
- [x] `test/{app}/utils/operation_log_test.exs`(socket / conn、認証前、不正カテゴリ)
- [x] テストが通る

## 6. Permission

- [x] `lib/{app}/utils/permission.ex`: `role_at_least?/2`、`can?/2`、`@required_roles`(`food_vault` は `emergency_ship_order: :admin`、`food_ship` は空)
- [x] `test/{app}/utils/permission_test.exs`(包含関係、未定義 action、`nil`)
- [x] テストが通る

## 7. 品質ゲート

- [ ] 両アプリの `mix.exs` に `credo` を追加し、`precommit` に `credo --all` を足す
- [ ] `mix credo gen.config` で `.credo.exs` を生成する
- [ ] `mix credo --all` を実行し、自作コードの指摘を直す(生成物だけ `files.excluded` に足す)
- [ ] `Makefile` に `check` を追加し、`.PHONY` に足す
- [ ] `config/test.exs` の DB `hostname` を `System.get_env("PGHOST", "db")` にする

## 8. CI

- [ ] `.github/workflows/ci.yml`: `pull_request` のみ、マトリクス 2 アプリ、`postgres:15.2`、`setup-beam`(Elixir 1.20.5 / OTP 29)、キャッシュ、compile → `format --check-formatted` → credo → test、`permissions: contents: read`
- [ ] ワークフローの YAML を構文チェックする(CI 自体は PR を出すまで実行できない)

## 9. 検証

- [ ] `make check` が両アプリで通る(警告ゼロ、format 差分なし、credo、test)
- [ ] 既存の各 5 件を含め、テストがすべて通る
- [ ] `mix format --check-formatted` を両アプリで確認する

## 10. 永続ドキュメントの更新

- [ ] `docs/architecture.md`: `ecto_ulid` → `ecto_ulid_next`(§1・§4・§16 #1)、§14 の「現状の不足」と未決事項 #5 の解消、Logger の JSON 形式の実装方針
- [ ] `docs/functional-design.md`・`docs/glossary.md`・`docs/repository-structure.md`・`docs/development-guidelines.md`: `ecto_ulid` の言及と「整備予定」(`make check` など)の表記を揃える
- [ ] `persistent-doc-updater` で影響を判定し、必要なものだけ更新する

## 11. 完了処理

- [ ] この tasklist の完了状況を最終更新する
- [ ] 作業ブランチ `claude/dreamy-turing-zhhryv` にコミットして push する(PR は指示があるときのみ作成)
- [ ] 振り返り(実装中に変えた設計・残課題)を末尾に追記する
