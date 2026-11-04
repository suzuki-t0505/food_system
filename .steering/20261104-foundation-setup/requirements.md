# 要求内容: 基盤整備(段階 0)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 0)、[architecture.md §4・§12・§14・§16](../../docs/architecture.md)
- 対象アプリ: `food_vault`(在庫)と `food_ship`(発送)の**両方**。共有ライブラリは作らず、同形のモジュールを各アプリに置く(repository-structure.md)
- 位置づけ: 認証(段階 1)以降の実装に入る前の土台。業務機能・業務テーブルは作らない

## 背景

両アプリは `mix phx.new` 直後の雛形で、ULID・共通スキーマ・Logger・権限判定・品質ゲート・CI が無い。`make credo` は `credo` 未導入のため動かず、`check` ターゲットと CI も無い。

## 要求(スコープ)

### 1. ULID 基盤(architecture §4、未決事項 #1)

- ULID の依存は **`ecto_ulid_next`**(`Ecto.ULID` を提供)を使う。両アプリの `mix.exs` に追加する
- Elixir 1.20 / Ecto 3.13 でコンパイル・テストが通ることを最初に確認する。通らない場合は自前実装に切り替えず、結果を報告して判断を仰ぐ
- 共通スキーママクロ `{App}.Schema`(`@primary_key {:id, Ecto.ULID, autogenerate: true}`、`@foreign_key_type Ecto.ULID`)を作る

### 2. Utils の雛形(architecture §12、§3.1)

- `{App}.Utils.Logger`: カテゴリ付きラッパー。`@categories` ホワイトリスト、未定義カテゴリは開発環境で例外、`redact` の自動マスク
- 本番(`config/runtime.exs` または `prod.exs`)は JSON 形式で出力し、メタデータに `request_id` / `remote_ip` / `mfa` / `file` / `line` を含める
- `{App}.Utils.OperationLog`: 「誰が・いつ・どのページで・どのデータで・何をしたか」を 1 行で出す雛形
- `{App}.Utils.Permission`: `can?/2` の雛形。`admin` ⊃ `staff` ⊃ `viewer` の包含判定のみ(個別の権限表は段階 1 以降)

### 3. 品質ゲート・CI(architecture §14、未決事項 #5)

- 両アプリに `credo` を追加し、`.credo.exs` を置く
- `Makefile` に `check` ターゲット(compile → format → credo → test)を追加する
- `mix.exs` の `precommit` エイリアスと `check` の関係を揃える
- PR 用の GitHub Actions ワークフロー(lint と test)を追加する

## 受け入れ条件

- [ ] 両アプリで ULID の生成・文字列⇔バイナリ変換・不正値の拒否がテストで確認できる
- [ ] `{App}.Schema` を使ったテスト用スキーマで ULID の主キー・外部キーが保存・取得できる
- [ ] Logger は未定義カテゴリで開発/テスト環境に例外を出し、`password` / `token` をマスクする(テストあり)
- [ ] 本番設定のログが JSON で、上記メタデータを含む(テストまたは設定の確認)
- [ ] `Permission.can?/2` の包含関係(`admin` ⊃ `staff` ⊃ `viewer`)がテストで確認できる
- [ ] `make check` が両アプリで通る(警告ゼロ、format 差分なし、credo、test)
- [ ] GitHub Actions が、`pull_request` トリガーで同じ `check` 相当を実行する(`main` への push では回さない)

## スコープ外

- `phx.gen.auth` と認証・ユーザー管理(段階 1。ULID 化の手順は段階 1 で扱う)
- 業務テーブル・Context・LiveView・在庫 API
- 本番 Dockerfile・デプロイ構成(未決事項 #3)、PDF ライブラリ(#4)
- 環境変数名の確定(#6。段階 1 以降で必要になった時点)

## 決定事項

- ULID の依存は `ecto_ulid_next` を使う(architecture.md の「`ecto_ulid` を候補」は、実装後に永続ドキュメントを更新して揃える)
- 本番向け JSON ログ形式は今回の Logger 雛形に**含める**
- GitHub Actions は **PR のみ**で回す
