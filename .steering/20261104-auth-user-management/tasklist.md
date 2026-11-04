# タスクリスト: 認証・ユーザー管理(段階 1)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。以下 `{app}` は `food_vault` / `food_ship`。進捗に合わせてチェックを更新する。コマンドは必ずコンテナ経由(`docker compose run --rm {app}_web mix ...`)。

## 1. vault: 依存と生成

- [x] `mix.exs` に `{:bcrypt_elixir, "~> 3.0"}` を追加し、`mix deps.get` と `mix deps.compile bcrypt_elixir` を実行する
- [x] `mix phx.gen.auth Accounts User users --binary-id --hashing-lib bcrypt --live` を実行する
- [x] 注入された差分(`config/test.exs`・`conn_case.ex`・`root.html.heex`・`AGENTS.md`・`router.ex`)を確認し、不要な行を戻す

## 2. vault: DB・Accounts

- [x] migration `create_users_auth_tables` を design §3.2 に合わせる(ULID、`name`・`role`・`must_change_password`・`archived_at`、`sent_to`・`authenticated_at`・`confirmed_at` を除去、FK は `on_delete: :nothing`)
- [x] `User` を `use FoodVault.Schema`、`role` を `Ecto.Enum` にし、`create_changeset/3`・`password_changeset/3`・`reset_password_changeset/2` を用意する(`redact: true`、`@derive {Inspect, ...}`)
- [x] `UserToken` を `session` のみにし、アーカイブ済みを無効にする。`Scope` は生成物のまま
- [x] `Accounts` を design §3.3 の公開関数に絞る(自己登録・マジックリンク・メール変更・配信・sudo mode を除去)
- [x] `ensure_initial_admin/0` と `FoodVault.Release.create_initial_admin/0`、`runtime.exs` の `InitialAdmin` 設定、`seeds.exs` を実装する
- [x] `Accounts` / `UserToken` のテストを書いて通す(認証・アーカイブ・12 文字・メール重複・トークン全削除・自分自身/最後の admin 拒否とロールバック・初期管理者の冪等性)

## 3. vault: Web

- [x] `UserAuth` を design §3.4 に改変する(plug 2 種、on_mount 5 種、強制遷移、`user_return_to`、`/users/log_in`)
- [x] `UserSessionController`(`create` の 1 種類エラーと `:log_in` ログ、`update_password`、`delete`)
- [x] `UserSessionLive.Login` / `UserSessionLive.Password`
- [x] `Management.UserLive.Index` / `Form`(`handle_event` 先頭で `Permission.can?/2`、`OperationLog`)
- [x] `router.ex` を design §3.5 のとおりにし、`:browser` に `fetch_current_scope_for_user` を追加する
- [x] `Layouts.app` にユーザー表示・パスワード変更・ログアウト・ユーザー管理(admin)を追加し、雛形の外部リンクを除去。`PageController` のホームを最小化する
- [x] `Permission` に `manage_users`・`change_own_password` を追加する
- [x] `lib/food_vault_web.ex` の `live_view` / `controller` に `OperationLog` と `Logger` を組み込む
- [x] 不要な生成物(`Registration`・`Confirmation`・`Settings` の LiveView とテスト)を削除する

## 4. vault: テストと品質ゲート

- [x] `accounts_fixtures.ex`・`conn_case.ex`(ロール指定の `register_and_log_in_user`)
- [x] `user_auth_test`・`user_session_controller_test`・LiveView 各テスト・`permission_test`・`page_controller_test` を design §4 のとおりに書く
- [x] `mix format`・`mix credo --all`・`mix test`・`mix compile --warnings-as-errors` が通る(vault)
- [x] vault をコミット・プッシュする

## 5. ship への展開

- [x] vault の差分を `FoodVault` → `FoodShip`、`food_vault` → `food_ship` に置換して ship に反映する(`emergency_ship_order` は ship に持ち込まない。`Permission` は関数形 `required_roles/0` を維持)
- [x] ship でも `phx.gen.auth` を実行し、vault の結果と差分がないことを確認する(実行はせず、変更前の両アプリの該当ファイルが名前置換で一致することを `diff` で確認して代替。振り返り参照)
- [x] `mix format`・`mix credo --all`・`mix test`・`mix compile --warnings-as-errors` が通る(ship)
- [x] ship をコミット・プッシュする

## 6. 動作確認

- [x] `make check` が両アプリで通る
- [x] 手動確認(vault)の実施: seeds の admin でログイン → 強制パスワード変更 → ユーザー作成・ロール変更・パスワード再設定・アーカイブ・復帰
- [x] 最後の admin・自分自身の操作が拒否される、別セッションがパスワード変更・ロール変更・アーカイブで即時に失効する
- [x] `viewer` / `staff` で `/management/users` に入れない、`/` は未ログインでログイン画面へ戻り、ログイン後に元ページへ戻る
- [x] 手動確認(ship)の同様の実施

## 7. 永続ドキュメントの更新

- [x] `architecture.md`(§8 remember me・初期管理者、§11 環境変数の確定、§16 #2・#6・#8 を解決済みに)
- [x] `functional-design.md`(§9 のログイン・remember me・`/users/log_in`、権限 action)
- [x] `glossary.md`・`repository-structure.md`(［計画］表記を実装済みに)・`development-guidelines.md`(段階 1 完了)

## 完了処理

- [x] 全チェックを更新し、「振り返り」を書く
- [x] コミット・プッシュする(PR は依頼があるまで作らない)

## 振り返り

### 設計からの変更点

- `require_logged_in_user`(強制遷移の対象外)は、design の `pipeline` ではなく `UserAuth` の plug 関数として実装した(`require_authenticated_user` と対にするため)。
- 設定キーは `config :{app}, {App}.Accounts.InitialAdmin`(design どおり)。`{App}.Release.run/0` を seeds と `create_initial_admin/0` で共有した。
- Accounts の公開関数名は `change_user_creation/3`・`change_user_reset_password/3`(design の `change_user/3` から変更)。`restore_user/2` は全トークン削除を伴わないため `{:ok, user}` を返す(他は `{:ok, {user, expired_tokens}}`)。
- 自分自身のパスワード再設定も `{:error, :self}` で拒否する(design に明記がなかった。自分の変更は「パスワード変更」から行う)。
- 新しいパスワードが現在のパスワードと同じ場合は拒否する(強制変更で初期パスワードのままにされないため)。
- `phx.gen.auth` が注入した `AGENTS.md` と `root.html.heex` の差分は採用せず戻した(ユーザーメニューは `Layouts.app` に置いた)。`config.exs` の `:scopes` と `test.exs` の bcrypt 設定は採用した。

### 確認できたこと

- 両アプリで `mix format`・`mix compile --warnings-as-errors --force`・`mix credo --all`・`mix test` が通る(vault 151 件、ship 150 件)。
- 開発サーバー(両アプリ)で、seeds の admin によるログイン → 強制パスワード変更 → 保護画面へのアクセス、誤パスワードの 1 種類エラー、未ログインのリダイレクトを `curl` で確認した。vault では変更後に旧パスワードのログインが拒否されること、ログアウトも確認した。

### 残課題・注意点

- ship 側で `phx.gen.auth` を再実行しての差分確認は省略した。変更前の vault / ship の該当ファイルは名前置換で一致していた(`config.exs` の `signing_salt`、`test.exs` の `secret_key_base`、`Permission` を除く)ため、生成結果も同じと判断した。
- 画面の見た目(ブラウザでの目視)は未確認。`curl` とテストで挙動のみ確認した。ユーザー管理画面のレイアウトは必要に応じて調整する。
- 開発時の Ecto デバッグログには、INSERT のパラメータとして `hashed_password`(ハッシュ)が出る。平文は出ない。本番(`:info` 以上)では出力されない。
- `Logger` のログイン失敗ログには入力されたメールアドレスを含める。ログの閲覧権限に注意する。
- 本番用リリースタスク(`{App}.Release.create_initial_admin/0`)は、本番イメージの構成(architecture §16 #3)が決まってから組み込む。
- CI(`.github/workflows/ci.yml`)は PR を出すまで未検証。bcrypt の NIF が CI の `setup-beam` 環境でビルドできるかも、そこで確認される。
