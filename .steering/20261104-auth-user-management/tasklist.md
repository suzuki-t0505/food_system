# タスクリスト: 認証・ユーザー管理(段階 1)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。以下 `{app}` は `food_vault` / `food_ship`。進捗に合わせてチェックを更新する。コマンドは必ずコンテナ経由(`docker compose run --rm {app}_web mix ...`)。

## 1. vault: 依存と生成

- [ ] `mix.exs` に `{:bcrypt_elixir, "~> 3.0"}` を追加し、`mix deps.get` と `mix deps.compile bcrypt_elixir` を実行する
- [ ] `mix phx.gen.auth Accounts User users --binary-id --hashing-lib bcrypt --live` を実行する
- [ ] 注入された差分(`config/test.exs`・`conn_case.ex`・`root.html.heex`・`AGENTS.md`・`router.ex`)を確認し、不要な行を戻す

## 2. vault: DB・Accounts

- [ ] migration `create_users_auth_tables` を design §3.2 に合わせる(ULID、`name`・`role`・`must_change_password`・`archived_at`、`sent_to`・`authenticated_at`・`confirmed_at` を除去、FK は `on_delete: :nothing`)
- [ ] `User` を `use FoodVault.Schema`、`role` を `Ecto.Enum` にし、`create_changeset/3`・`password_changeset/3`・`reset_password_changeset/2` を用意する(`redact: true`、`@derive {Inspect, ...}`)
- [ ] `UserToken` を `session` のみにし、アーカイブ済みを無効にする。`Scope` は生成物のまま
- [ ] `Accounts` を design §3.3 の公開関数に絞る(自己登録・マジックリンク・メール変更・配信・sudo mode を除去)
- [ ] `ensure_initial_admin/0` と `FoodVault.Release.create_initial_admin/0`、`runtime.exs` の `InitialAdmin` 設定、`seeds.exs` を実装する
- [ ] `Accounts` / `UserToken` のテストを書いて通す(認証・アーカイブ・12 文字・メール重複・トークン全削除・自分自身/最後の admin 拒否とロールバック・初期管理者の冪等性)

## 3. vault: Web

- [ ] `UserAuth` を design §3.4 に改変する(plug 2 種、on_mount 5 種、強制遷移、`user_return_to`、`/users/log_in`)
- [ ] `UserSessionController`(`create` の 1 種類エラーと `:log_in` ログ、`update_password`、`delete`)
- [ ] `UserSessionLive.Login` / `UserSessionLive.Password`
- [ ] `Management.UserLive.Index` / `Form`(`handle_event` 先頭で `Permission.can?/2`、`OperationLog`)
- [ ] `router.ex` を design §3.5 のとおりにし、`:browser` に `fetch_current_scope_for_user` を追加する
- [ ] `Layouts.app` にユーザー表示・パスワード変更・ログアウト・ユーザー管理(admin)を追加し、雛形の外部リンクを除去。`PageController` のホームを最小化する
- [ ] `Permission` に `manage_users`・`change_own_password` を追加する
- [ ] `lib/food_vault_web.ex` の `live_view` / `controller` に `OperationLog` と `Logger` を組み込む
- [ ] 不要な生成物(`Registration`・`Confirmation`・`Settings` の LiveView とテスト)を削除する

## 4. vault: テストと品質ゲート

- [ ] `accounts_fixtures.ex`・`conn_case.ex`(ロール指定の `register_and_log_in_user`)
- [ ] `user_auth_test`・`user_session_controller_test`・LiveView 各テスト・`permission_test`・`page_controller_test` を design §4 のとおりに書く
- [ ] `mix format`・`mix credo --all`・`mix test`・`mix compile --warnings-as-errors` が通る(vault)
- [ ] vault をコミット・プッシュする

## 5. ship への展開

- [ ] vault の差分を `FoodVault` → `FoodShip`、`food_vault` → `food_ship` に置換して ship に反映する(`emergency_ship_order` は ship に持ち込まない。`Permission` は関数形 `required_roles/0` を維持)
- [ ] ship でも `phx.gen.auth` を実行し、vault の結果と差分がないことを確認する
- [ ] `mix format`・`mix credo --all`・`mix test`・`mix compile --warnings-as-errors` が通る(ship)
- [ ] ship をコミット・プッシュする

## 6. 動作確認

- [ ] `make check` が両アプリで通る
- [ ] 手動確認(vault)の実施: seeds の admin でログイン → 強制パスワード変更 → ユーザー作成・ロール変更・パスワード再設定・アーカイブ・復帰
- [ ] 最後の admin・自分自身の操作が拒否される、別セッションがパスワード変更・ロール変更・アーカイブで即時に失効する
- [ ] `viewer` / `staff` で `/management/users` に入れない、`/` は未ログインでログイン画面へ戻り、ログイン後に元ページへ戻る
- [ ] 手動確認(ship)の同様の実施

## 7. 永続ドキュメントの更新

- [ ] `architecture.md`(§8 remember me・初期管理者、§11 環境変数の確定、§16 #2・#6・#8 を解決済みに)
- [ ] `functional-design.md`(§9 のログイン・remember me・`/users/log_in`、権限 action)
- [ ] `glossary.md`・`repository-structure.md`(［計画］表記を実装済みに)・`development-guidelines.md`(段階 1 完了)

## 完了処理

- [ ] 全チェックを更新し、「振り返り」を書く
- [ ] コミット・プッシュする(PR は依頼があるまで作らない)

## 振り返り

(実装中に変えた設計・残課題を記録する)
