# 要求内容: 認証・ユーザー管理(段階 1)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 1)、[product-requirements.md F-A1・F-A2](../../docs/product-requirements.md)、[functional-design.md §9・§10](../../docs/functional-design.md)、[architecture.md §8・§16](../../docs/architecture.md)
- 対象アプリ: `food_vault`(在庫)と `food_ship`(発送)の**両方**。ユーザー・DB・認証は共有せず、同形のモジュールを各アプリに置く(repository-structure.md)
- 位置づけ: 段階 0(基盤整備)の次。以降の業務機能(段階 2〜)はすべてこの認証と `current_scope` を前提にする

## 背景

両アプリには認証・ユーザー・マイグレーションが一切ない。`Layouts.app` は `current_scope` を受け取れるが、中身は Phoenix 雛形のままで、ログイン・ログアウト・権限検査の仕組みが無い。段階 0 で `Permission.can?/2` と `OperationLog` の雛形を置いたが、`current_scope` が揃わないため `use {AppWeb}, :live_view` / `:controller` への組み込みは見送っている。

## 要求(スコープ)

### 1. 認証(F-A1、functional-design §9.1)

- `mix phx.gen.auth` を土台に、**自己登録・マジックリンク・メール確認・メール変更を取り除き、メール＋パスワード認証のみ**にする
- パスワードは bcrypt、12 文字以上。平文をログ・画面に出さない
- ログイン失敗のエラーは「メールアドレスまたはパスワードが正しくありません。」の 1 種類のみ(存在しないメール・パスワード誤り・アーカイブ済みのいずれも同一)
- 未ログインの画面アクセスはログイン画面へ遷移し、ログイン後は元のページへ戻る
- 現在ユーザーは `current_scope.user` で扱い、`Layouts.app` に渡す。assign は plug と `on_mount` の 2 箇所のみ
- 「ログインしたままにする」(remember me)は `phx.gen.auth` の既定を残す
- ログイン成功・失敗を Logger カテゴリ `:log_in` で記録する

### 2. ユーザーとセッション(F-A1・F-A2、functional-design §9.2)

- `users`: `email`(citext・一意)、`name`、`hashed_password`(`redact: true`)、`role`(`admin` / `staff` / `viewer`)、`must_change_password`、`archived_at`
- `users_tokens`: セッション用トークン(remember me 用の既定を含む)
- ID・外部キーは ULID(`{App}.Schema`)
- パスワード変更・ロール変更・アーカイブ時は、そのユーザーの全トークンを同一トランザクションで削除し、全セッションを即時に失効させる

### 3. ユーザー管理(F-A2)

- 画面: ログイン・ログアウト、自分のパスワード変更(全ロール)、ユーザー管理(一覧・登録・ロール変更・パスワード再設定・アーカイブ・復帰。`admin` のみ)
- 管理者が設定した初期/再設定パスワードでのログイン直後は、パスワード変更画面へ強制遷移する
- 有効な `admin` を常に 1 人以上残す。最後の `admin` と自分自身のロール変更・アーカイブは Context で拒否する
- アーカイブ済みユーザーはログインできない。メールアドレスは再利用不可。復帰は `archived_at` を NULL に戻す

### 4. 認可 3 層(functional-design §9.4)

- ① HTTP plug: `require_authenticated_user` / `require_authenticated_admin_user`
- ② `on_mount`: `:ensure_authenticated` / `:ensure_authenticated_staff` / `:ensure_authenticated_admin`。`live_session` には plug と同じ強さのフックを必ず指定する
- ③ イベント単位: `handle_event` の先頭で `Permission.can?/2` を検査し、不許可なら `put_flash(:error, "権限がありません。")`
- 権限表(ユーザー管理などの action)を `Permission` に追加する

### 5. 初期管理者と持ち越し事項

- 初期管理者は seeds(開発)とリリースタスク(本番)で作成する。初期パスワードは `runtime.exs` 経由の環境変数から読み、作成後に `must_change_password = true` にする(環境変数名は design.md で確定)
- 段階 0 から持ち越した `OperationLog` の `use {AppWeb}, :live_view` / `:controller` への組み込みを行う
- `Layouts.app` にユーザー名とログアウトを追加し、雛形の外部リンクを除去する

## 受け入れ条件

- [ ] メール＋パスワードでログイン・ログアウトできる。自己登録・マジックリンク・メール確認の経路が存在しない
- [ ] ログイン失敗のメッセージが 1 種類のみで、メールの存在有無・アーカイブ済みかどうかが分からない
- [ ] 12 文字未満のパスワードは登録・変更できない。`hashed_password` と平文がログに出ない
- [ ] 未ログインで保護画面へアクセスするとログイン画面へ遷移し、ログイン後に元のページへ戻る
- [ ] `viewer` / `staff` / `admin` ごとに、plug・`on_mount`・`handle_event` のそれぞれで許可・拒否される(ロール別テストあり)
- [ ] パスワード変更・ロール変更・アーカイブをしたユーザーの既存セッションが即時に失効する
- [ ] `admin` のみがユーザーの作成・ロール変更・パスワード再設定・アーカイブ・復帰を実行できる
- [ ] 管理者設定のパスワードでのログイン直後、パスワード変更画面へ強制遷移し、変更するまで他画面へ進めない
- [ ] 最後の `admin` と自分自身のロール変更・アーカイブが拒否される
- [ ] アーカイブ済みユーザーがログインできない
- [ ] ログイン成功・失敗が `:log_in` で記録される
- [ ] 上記が `food_vault` と `food_ship` の両方で満たされ、`make check` が両アプリで通る(警告ゼロ、format 差分なし、credo、test)

## スコープ外

- ログイン試行制限・アカウントロック・メールによるパスワード再設定(P2)
- 在庫と発送のユーザー共通化・シングルサインオン(P2)
- MFA
- 業務テーブル・業務 Context・業務画面(段階 2 以降)
- 本番 Dockerfile・デプロイ構成(未決事項 #3)。リリースタスクはモジュールとして用意するが、本番イメージへの組み込みは扱わない
- ユーザー管理専用の監査テーブル(操作ログ=Logger/OperationLog で扱う)

## 決定事項

- 対象は `food_vault` と `food_ship` の両方を同時に実装する(vault で先に作り、ship へ同形で展開)
- remember me は `phx.gen.auth` の既定を残す。docs が対象外としていた部分は、実装後に `architecture.md`(未決事項 #8)と `functional-design.md` を更新して揃える
- ステアリング文書は requirements → design → tasklist の順に 1 ファイルずつ承認を得る

## 未確定(design.md で決める)

- 初期管理者用の環境変数名(architecture §16 #6)
- 権限表の action 名
- セッションの有効期間と remember me の期間(`phx.gen.auth` 既定は 14 日・60 日)と、session cookie の暗号化(`encryption_salt`)の要否
- 開発用 LiveDashboard (`/dev/dashboard`) を `admin` 限定にするか
