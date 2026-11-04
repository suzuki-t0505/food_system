# 設計: 認証・ユーザー管理(段階 1)

要求は [requirements.md](requirements.md)。両アプリ(`food_vault` / `food_ship`)に**同じ構成**を置く(共有ライブラリは作らない)。以下 `{App}` は `FoodVault` / `FoodShip`、`{app}` は `food_vault` / `food_ship`。

## 1. 現状(調査結果)

- 認証・ユーザー・マイグレーションは 0 件。`Layouts.app` は `current_scope` attr を持つが、中身は雛形のまま。`/` は雛形のランディングページ(`PageController`)で認証なし
- 段階 0 で `{App}.Schema`、`Utils.Logger`(`:log_in` カテゴリ)、`Utils.OperationLog`(`current_scope.user.id` を「ある場合だけ」取り出す)、`Utils.Permission`(`can?/2`、未定義 action は拒否)がある
- 使い捨てコピーで `mix phx.gen.auth Accounts User users --binary-id --hashing-lib bcrypt --live` を**実際に実行して確認**した(Phoenix 1.8.16)。生成物の要点:
  - `users`: `email`(citext)、`hashed_password`、`confirmed_at`、`timestamps`。`users_tokens`: `id`(binary_id)、`user_id`(`on_delete: :delete_all`)、`token`、`context`、`sent_to`、`authenticated_at`、`inserted_at` のみ
  - セッション有効期間は `inserted_at > ago(14, "day")` で判定。`UserAuth` は 7 日経過で再発行し、remember me cookie(14 日)を同時に更新する
  - `Accounts.sudo_mode?/2` と `on_mount(:require_sudo_mode)`(設定画面でのメール・パスワード変更に使用)、`authenticated_at` がある
  - ルートは `/users/log-in`(ハイフン)。docs と coding-rules §8.4 は `/users/log_in`(アンダースコア)
  - `AGENTS.md`・`config/test.exs`(`bcrypt` の `log_rounds: 1`)・`conn_case.ex`(`register_and_log_in_user`)・`root.html.heex`(ユーザーメニュー)にも差分が入る
- architecture §16 #2 の確認結果: `users_tokens` のカラム構成は docs(`user_id` / `token` / `context` / `inserted_at`)に `sent_to`・`authenticated_at` が余分。セッション有効期間は `inserted_at` ベースで設計と一致する

## 2. 方針

| 項目 | 決定 | 理由 |
| :-- | :-- | :-- |
| 生成 | vault でコンテナ内に `phx.gen.auth` を実行し、下記のとおり削減・改変。ship は vault の結果を `{App}` 置換でコピーする | 両アプリの同形を保つ。ship 側でも生成して差分がないことを確認する |
| 削除するもの | 自己登録(`Registration`)、マジックリンク(`Confirmation`、`login_user_by_magic_link`)、メール変更、配信系(`UserNotifier`、`deliver_*`)、`confirmed_at`、`sent_to`、`authenticated_at`、sudo mode | requirements のとおりパスワード認証のみ。メールを送らない。sudo mode は「現在のパスワード必須」で代替する |
| ULID | `User` / `UserToken` は `use {App}.Schema`。migration は `add :id, :binary_id, primary_key: true`、FK は `references(:users, type: :binary_id, on_delete: :nothing)` | architecture §4。ユーザーは削除せずアーカイブするため `on_delete: :nothing`。トークンは Context が明示的に削除する |
| ルート | 認証系は `/users/log_in`、`/users/log_out`、`/users/password`(パスワード変更)。`admin` 専用は `/management/users`。docs の URL 規約に合わせ、生成物の `log-in` は `log_in` に直す | coding-rules §8.4 |
| remember me | `phx.gen.auth` の既定を残す(cookie 14 日、`maybe_write_remember_me_cookie`、ログイン画面のチェックボックス) | requirements の決定事項 |
| セッション有効期間 | 既定どおり 14 日、7 日で再発行。変更しない | 既定を踏襲。業務要件が出た時点で見直す |
| cookie の暗号化 | しない(`encryption_salt` を追加しない)。署名のみ | cookie の中身はランダムなトークンのみで、盗まれた時点でセッションが奪われる点は暗号化の有無で変わらない。失効は DB トークン削除で行う |
| トークン保存 | セッショントークンは既定どおり生のまま DB に保存(署名済み cookie の値と一致させる) | 既定の設計。失効は行削除で行う |
| 初期管理者の環境変数 | `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD`(architecture §11 の命名案を確定) | 命名案どおり |
| 権限 action | `:manage_users`(`admin`)、`:change_own_password`(`viewer` 以上)。在庫・発送の業務 action は各段階で追加 | 権限表(functional-design §9.3)の「ユーザー管理」「自分のパスワード変更」と 1 対 1 |
| 開発用ルート | `/dev/dashboard` は変更しない(`dev_routes` は開発のみ)。メールを送らなくなるため `/dev/mailbox` は残すが使わない | 変更を最小にする。本番構成(#3)で改めて検討 |
| ユーザー情報の編集 | 名前・メールアドレスの編集画面は作らない(登録時のみ) | 要件(F-A2)に無い。必要になった時点で追加 |
| ログ | ログイン成功を `:log_in` の info、失敗を warning で記録する。失敗時は入力されたメールのみを出し、パスワードは出さない | architecture §12。メールの有無は画面に出さない |
| `/` | 認証必須にする(ログイン後のホーム)。雛形のランディングページは最小のホーム画面に置き換える | 「未ログインの画面アクセスはログイン画面へ」の例外を作らない |

## 3. 変更するファイル

### 3.1 依存・設定(両アプリ)

- `mix.exs`: `{:bcrypt_elixir, "~> 3.0"}` を追加
- `config/test.exs`: `config :bcrypt_elixir, :log_rounds, 1`(生成物の注入を採用)
- `config/runtime.exs`: `config :{app}, {App}.Accounts.InitialAdmin, email: System.get_env("INITIAL_ADMIN_EMAIL") || (開発用デフォルト), password: System.get_env("INITIAL_ADMIN_PASSWORD") || (開発用デフォルト)`。開発用デフォルトは `dev` / `test` のときのみ。本番は必須とせず、未設定ならリリースタスクが「設定がありません。」と報告して終了する(初期作成時のみ必須)
- `AGENTS.md`: 生成物の注入を確認し、不要な箇所は戻す

### 3.2 DB(両アプリ)

`priv/repo/migrations/{timestamp}_create_users_auth_tables.exs`(新規)

- `execute "CREATE EXTENSION IF NOT EXISTS citext", ""`
- `users`: `id`(binary_id)、`email`(citext、NOT NULL)、`name`(string、NOT NULL)、`hashed_password`(string、NOT NULL)、`role`(string、NOT NULL、default `viewer`)、`must_change_password`(boolean、NOT NULL、default true)、`archived_at`(utc_datetime)、`timestamps(type: :utc_datetime)`。`unique_index(:users, [:email])`
- `users_tokens`: `id`(binary_id)、`user_id`(NOT NULL、FK)、`token`(binary、NOT NULL)、`context`(string、NOT NULL)、`timestamps(type: :utc_datetime, updated_at: false)`。`index(:users_tokens, [:user_id])`、`unique_index(:users_tokens, [:context, :token])`
- `role` は `Ecto.Enum`(DB は文字列)。値の制限は schema と changeset で行う

### 3.3 Accounts(両アプリ)

`lib/{app}/accounts.ex`(新規)、`lib/{app}/accounts/user.ex`、`user_token.ex`、`scope.ex`

- `User`: `use {App}.Schema`、`@derive {Inspect, except: [:password, :hashed_password]}`、`password` は `virtual: true, redact: true`、`hashed_password` は `redact: true`。`role` は `Ecto.Enum, values: [:viewer, :staff, :admin]`。changeset は用途別: `create_changeset/3`(管理者による登録。`email`・`name`・`role`・`password`、`must_change_password` は常に true)、`password_changeset/3`(本人変更。`current_password` の検証、12 文字以上、`must_change_password` を false)、`reset_password_changeset/2`(管理者による再設定。`must_change_password` を true)
- パスワードの上限は bcrypt の 72 バイトに合わせて検証する(生成物の既定を踏襲)
- `UserToken`: `use {App}.Schema`。コンテキストは `session` のみ。`build_session_token/1`、`verify_session_token_query/1`(`inserted_at` で期間判定。アーカイブ済みは除外)、`by_token_and_context_query/2`、`by_user_query/1`
- `Scope`: 生成物のとおり(`for_user/1`)
- `Accounts` の公開関数:

| 関数 | 内容 |
| :-- | :-- |
| `get_user_by_email_and_password/2` | メール・パスワードで取得。アーカイブ済み・存在しない場合は `nil`(`Bcrypt.no_user_verify/0` で時間差を作らない)。画面は 1 種類のエラーのみ |
| `get_user_by_session_token/1` | トークンから `{user, inserted_at}`。アーカイブ済みは返さない |
| `generate_user_session_token/1`、`delete_user_session_token/1` | 生成物のとおり |
| `list_users/0`、`get_user!/1` | 一覧(アーカイブ済みを含む。作成順)・取得 |
| `change_user/3`、`create_user/2` | 管理者による登録。`create_user(scope, attrs)` は `:manage_users` が無ければ `{:error, :forbidden}` |
| `update_user_role/3` | `(scope, user, role)`。自分自身は `{:error, :self}`、最後の `admin` の降格は `{:error, :last_admin}`。成功時は対象の全トークンを同一トランザクションで削除し、`{:ok, {user, expired_tokens}}` |
| `reset_user_password/3` | `(scope, user, attrs)`。`must_change_password` を true にし、全トークン削除 |
| `archive_user/2`、`restore_user/2` | アーカイブ(`archived_at` を設定、全トークン削除)、復帰(NULL に戻す)。自分自身・最後の `admin` は `{:error, :self}` / `{:error, :last_admin}` |
| `change_user_password/3`、`update_user_password/2` | 本人の変更(`current_password` 必須)。成功時は `must_change_password` を false にし、全トークン削除。`{:ok, {user, expired_tokens}}` |
| `ensure_initial_admin/0` | 有効な `admin` がいなければ、`InitialAdmin` の設定から作成(`must_change_password = true`)。すでにいれば何もしない(冪等)。設定が無ければ `{:error, :not_configured}` |

- 「最後の `admin`」の判定は、トランザクション内で有効な `admin` を `FOR UPDATE` でロックして数える(同時実行で 0 人にならないようにする)。ロール変更・アーカイブ・復帰・トークン削除は `Repo.transact/1` の同一トランザクション
- Context でも `Permission.can?(scope.user, :manage_users)` を検査する(Web 層の検査と二重化)
- `{App}.Release.create_initial_admin/0`(新規 `lib/{app}/release.ex`): `ensure_initial_admin/0` を呼び、結果を標準出力に出す。`priv/repo/seeds.exs` からも呼ぶ。本番イメージへの組み込みは未決事項 #3 のため扱わない

### 3.4 Web: plug・on_mount・コントローラ(両アプリ)

`lib/{app}_web/user_auth.ex`(新規。生成物を改変)

- `fetch_current_scope_for_user/2`: 生成物のとおり(plug。`current_scope` を assign する 1 箇所目)
- `mount_current_scope/2`(on_mount。2 箇所目): アーカイブ済みは `get_user_by_session_token/1` が返さないため未ログイン扱いになる
- plug: `require_authenticated_user/2`(全ロール)、`require_authenticated_admin_user/2`(`admin`、不許可は `put_flash(:error, "権限がありません。")` で `/` へ)
- on_mount: `:ensure_authenticated`、`:ensure_authenticated_staff`、`:ensure_authenticated_admin`、`:mount_current_scope`(ログイン画面用)、`:ensure_authenticated_for_password_change`(パスワード変更画面用。`must_change_password` の強制遷移の対象外)
- 強制遷移: `must_change_password` が true のユーザーは、plug・on_mount ともに `/users/password` 以外の保護された画面から `/users/password` へリダイレクトする。`/users/password` と `log_out` のみ到達できる
- 未ログインのアクセスは `user_return_to` に GET のパスを保存してログイン画面へ。ログイン後に戻る(生成物の `maybe_store_return_to/1`)
- 失効: `disconnect_sessions/1`(生成物のとおり)を `Accounts` の戻り値の `expired_tokens` に対して Web 層で呼ぶ(開いている LiveView が切断される)
- `signed_in_path/1`: `/`

`lib/{app}_web/controllers/user_session_controller.ex`(生成物を改変)

- `create`: メール＋パスワードで認証。失敗時は「メールアドレスまたはパスワードが正しくありません。」を `put_flash(:error, ...)` でログイン画面へ戻す(メールのみ引き継ぐ)。成功時は `:log_in` で記録して `log_in_user/3`
- `update_password`: パスワード変更後の再ログイン(LiveView の `phx-trigger-action` から POST)。成功したら `OperationLog.info(conn, ..., :update, user)` と `disconnect_sessions/1`、新しいセッションで `log_in_user/3`
- `delete`: ログアウト

### 3.5 Web: LiveView・ルーター・レイアウト(両アプリ)

- `lib/{app}_web/live/user_session_live/login.ex`: メール・パスワード・「ログインしたままにする」。`phx-trigger-action` で POST `/users/log_in`
- `lib/{app}_web/live/user_session_live/password.ex`: 現在のパスワード・新しいパスワード・確認。強制遷移中はその旨のメッセージを出す。送信で `Accounts.change_user_password/3` を検証し、通れば POST `/users/update_password`
- `lib/{app}_web/live/management/user_live/index.ex`: 一覧(メール・名前・ロール・状態)。ロール変更、アーカイブ、復帰、パスワード再設定の操作。`handle_event` の先頭で `Permission.can?(@current_scope.user, :manage_users)` を検査し、不許可は `put_flash(:error, "権限がありません。")`。成功時は `OperationLog.info(socket, ..., :update, user)`。`{:error, :self}` / `{:error, :last_admin}` は画面にエラーとして表示する
- `lib/{app}_web/live/management/user_live/form.ex`: 登録(`live_action :new`)と再設定(`:reset_password`)のフォーム。登録は `OperationLog.info(socket, ..., :create, user)`
- `router.ex`:

```elixir
scope "/", {App}Web do
  pipe_through [:browser]
  live_session :current_user, on_mount: [{{App}Web.UserAuth, :mount_current_scope}] do
    live "/users/log_in", UserSessionLive.Login, :new
  end
  post "/users/log_in", UserSessionController, :create
  delete "/users/log_out", UserSessionController, :delete
end

scope "/", {App}Web do
  pipe_through [:browser, :require_logged_in_user]   # 強制遷移の対象外
  live_session :password_change, on_mount: [{{App}Web.UserAuth, :ensure_authenticated_for_password_change}] do
    live "/users/password", UserSessionLive.Password, :edit
  end
  post "/users/update_password", UserSessionController, :update_password
end

scope "/", {App}Web do
  pipe_through [:browser, :require_authenticated_user]
  live_session :require_authenticated_user, on_mount: [{{App}Web.UserAuth, :ensure_authenticated}] do
    get "/", PageController, :home
  end
end

scope "/management", {App}Web.Management do
  pipe_through [:browser, :require_authenticated_admin_user]
  live_session :require_authenticated_admin_user, on_mount: [{{App}Web.UserAuth, :ensure_authenticated_admin}] do
    live "/users", UserLive.Index, :index
    live "/users/new", UserLive.Form, :new
    live "/users/:id/reset_password", UserLive.Form, :reset_password
  end
end
```

  `get "/"` は LiveView ではないため `live_session` の外に置く(上は構成の説明用。実装では `scope` 内の通常ルートにする)。`:browser` に `plug :fetch_current_scope_for_user` を追加する
- `Layouts.app`: `current_scope` があれば名前・ロール・「パスワード変更」・「ログアウト」(`DELETE /users/log_out`)・`admin` には「ユーザー管理」を表示する。雛形の外部リンク(Website / GitHub / Get Started)を除去する。`core_components.ex` は改変しない(coding-rules §10.1)
- `PageController`: `home` を最小のホーム画面(アプリ名とログイン中のユーザー)に置き換える。雛形のランディング用テンプレートを削除する
- `lib/{app}_web.ex`: `live_view` と `controller` に `alias {App}.Utils.OperationLog` と `use {App}.Utils.Logger` を組み込む(段階 0 からの持ち越し)

### 3.6 Permission(両アプリ)

- `@required_roles`(ship は関数 `required_roles/0`)に追加: `manage_users: :admin`、`change_own_password: :viewer`。vault の `emergency_ship_order: :admin` は維持する

## 4. テスト

| ファイル | 内容 |
| :-- | :-- |
| `test/support/fixtures/accounts_fixtures.ex` | `user_fixture/1`(ロール指定)、`admin_fixture/1`、`user_scope_fixture/1`、`set_password` 相当(`must_change_password` を false にする) |
| `test/support/conn_case.ex` | `register_and_log_in_user`(ロール指定可)、`log_in_user/2` |
| `test/{app}/accounts_test.exs` | 認証の成功・失敗・アーカイブ済み、12 文字未満の拒否、メールの重複(大文字小文字を区別しない)、`create_user` の権限、ロール変更・アーカイブ・再設定でトークン全削除、自分自身と最後の `admin` の拒否(ロールバック確認)、`ensure_initial_admin/0` の冪等性 |
| `test/{app}/accounts/user_token_test.exs` | 期間外のトークンが無効、アーカイブ済みユーザーのトークンが無効 |
| `test/{app}_web/user_auth_test.exs` | 未ログイン→ログイン→元ページ復帰、remember me、`must_change_password` の強制遷移(対象外パスの確認)、plug・on_mount のロール別許可/拒否、アーカイブ後にセッション失効 |
| `test/{app}_web/controllers/user_session_controller_test.exs` | ログイン成功/失敗(メッセージが 1 種類)、ログアウト、パスワード変更後の再ログイン、`:log_in` ログ(`capture_log` でレベルを一時的に下げる) |
| `test/{app}_web/live/user_session_live/*_test.exs` | ログイン画面、パスワード変更画面(現在のパスワード誤り、確認不一致、強制遷移中) |
| `test/{app}_web/live/management/user_live/*_test.exs` | `admin` のみ表示・操作可、`staff` / `viewer` はリダイレクト、`handle_event` を直接送って権限が無ければ拒否(`:if` だけに頼らない)、最後の `admin`・自分自身の操作がエラー表示 |
| `test/{app}/utils/permission_test.exs` | `manage_users` / `change_own_password` の追加 |
| `test/{app}_web/controllers/page_controller_test.exs` | 未ログインはログイン画面へ、ログイン後は 200 |

## 5. 実施順

1. vault: `bcrypt_elixir` 追加 → `phx.gen.auth` 実行 → 削減・ULID 化 → migration → Accounts・User・UserToken・Scope（Accounts のテストを先に通す）
2. vault: `UserAuth`・コントローラ・LiveView・ルーター・レイアウト・Permission・`OperationLog` 組み込み → テスト → `make check`(vault のみ)
3. vault: seeds・`Release`・`runtime.exs` → 手動確認(`docker compose up`)
4. ship: vault の結果を `{App}` 置換でコピー。ship 側でも `phx.gen.auth` を実行して差分がないことを確認 → `make check`
5. 永続ドキュメントの更新(architecture §8・§11・§16 #2・#6・#8、functional-design §9、glossary、repository-structure、development-guidelines)

## 6. 影響範囲・リスク

- `phx.gen.auth` は `config/test.exs`・`conn_case.ex`・`root.html.heex`・`AGENTS.md`・`router.ex` に注入する。注入された差分を採否判断してから残す(余分な行を持ち込まない)
- 雛形の `PageController` テストとテンプレートを置き換えるため、既存テストの更新が必要
- `bcrypt_elixir` は NIF のためビルド環境が必要。開発イメージに `gcc` / `make` があり、使い捨てコピーで `mix deps.compile bcrypt_elixir --force`(`MIX_ENV=dev`)が成功することを確認済み。`deps.get` 直後の通常 `deps.compile` は `_build` が古いと失敗するため、実装時は `deps.compile` を明示してから進める
- 最後の `admin` の同時実行による 0 人化は `FOR UPDATE` で防ぐ。テストは直列のため、並行性そのものは設計レビューで確認する
- `Logger` のメールアドレスは機微データ扱いにしていない(`@redact_keys` に含まれない)。失敗ログに入力されたメールを出すため、運用でログの閲覧権限に注意する
- `/dev/mailbox` は不要になるが、Swoosh と `Mailer` は残す(将来のメール再設定=P2 のため)
