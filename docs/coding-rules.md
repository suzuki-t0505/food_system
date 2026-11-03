# Elixir / Phoenix コーディングルール (Coding Rules)

本書は Unifield の実装から抽出した、**他の Elixir / Phoenix プロジェクトにも持ち出せる**コーディングルールである。

- 本プロジェクト固有の運用（デプロイ手順・ステアリングファイル・業務ドメイン）は [development-guidelines.md](development-guidelines.md) を参照。
- 本書は「どう書くか」だけを扱う。

## 目次

| 章 | 内容 |
|----|------|
| [1. 基本原則](#1-基本原則) | 品質ゲート・フォーマッタ・Lint |
| [2. レイヤリングとディレクトリ構成](#2-レイヤリングとディレクトリ構成) | Context + スキーマの2層・ファイル命名 |
| [3. モジュール共通の書き方](#3-モジュール共通の書き方) | `@moduledoc`・alias・typespec 方針 |
| [4. ドメイン層 — Context](#4-ドメイン層--context) | 関数命名・引数順・戻り値の契約・`@doc` |
| [5. Ecto スキーマ](#5-ecto-スキーマ) | スキーママクロ・changeset・バリデーション・制約 |
| [6. クエリ](#6-クエリ) | クエリビルダ・preload・ページネーション |
| [7. トランザクションとエラーハンドリング](#7-トランザクションとエラーハンドリング) | `Ecto.Multi`・`with` の使いどころ |
| [8. Web 層 — ルーティング](#8-web-層--ルーティング) | pipeline・live_session・URL 設計 |
| [9. Web 層 — LiveView](#9-web-層--liveview) | コールバック順・assign・遷移・flash |
| [10. Web 層 — コンポーネントと HEEx](#10-web-層--コンポーネントと-heex) | コンポーネント設計・HEEx 記法 |
| [11. 認証・認可](#11-認証認可) | 3層の認可・所有権チェック |
| [12. ログと監査ログ](#12-ログと監査ログ) | Logger ラッパー・操作ログ |
| [13. 設定と秘密情報](#13-設定と秘密情報) | `runtime.exs` への集約 |
| [14. マイグレーション](#14-マイグレーション) | 命名・`execute/2`・後方互換 |
| [15. テスト](#15-テスト) | 命名・フィクスチャ・mock |
| [16. 日時・数値・文言](#16-日時数値文言) | UTC 保存・金額計算・文体 |
| [17. 禁止事項一覧](#17-禁止事項一覧) | レビュー用チェックリスト |
| [付録 A. 導入チェックリスト](#付録-a-他プロジェクトへの導入チェックリスト) | 他プロジェクトへの移植手順 |

---

## 0. このドキュメントについて

### 0.1 前提スタック

Elixir 1.18 / Phoenix 1.7 / LiveView 1.0 / Ecto 3.x / PostgreSQL / Tailwind CSS。
LiveView 中心（API 専用アプリは対象外）。

### 0.2 表記規約

| 表記 | 意味 | Unifield での値 |
|------|------|----------------|
| `{App}` | アプリのモジュール名 | `Unifield` |
| `{AppWeb}` | Web 層のモジュール名 | `UnifieldWeb` |
| `{app}` | OTP アプリ名（atom） | `:unifield` |

コード例は2種類ある。どちらも**先頭行のコメントにファイルの置き場所**を書いてある。

- **汎用例**: `{App}` で書かれた例。モジュール名を置換してそのまま使う（コメントも `lib/{app}/...` 表記）。
- **実コード例**: Unifield の実際のコードをそのまま載せたもの（コメントは `lib/unifield/...` 表記）。
  自分のプロジェクトの名前に読み替えて使う。

### 0.3 ラベル

| ラベル | 意味 |
|--------|------|
| `[必須]` | 破ってはいけない。レビューで指摘する |
| `[推奨]` | 特段の理由がなければ従う |

---

## 1. 基本原則

### 1.1 品質ゲートを1コマンドに集約する `[必須]`

4つのチェックを1つのコマンドにまとめ、**プッシュ前に必ず全部パスさせる**。

```make
# Makefile

mix_compile:
	docker compose run --rm web mix compile --warnings-as-errors --force

mix_format:
	docker compose run --rm web mix format

mix_credo:
	docker compose run --rm web mix credo --all

mix_test:
	docker compose run --rm web mix test

check: mix_compile mix_format mix_credo mix_test
```

- **コンパイル警告はエラー扱い**（`--warnings-as-errors`）。未使用変数・非推奨 API を放置しない。
- 開発コマンドはコンテナ経由に統一し、ホストで直接 `mix` を叩かない（環境差分を消すため）。
- Docker を使わないプロジェクトでは `mix.exs` の `aliases` に `check: [...]` を置く。
- **CI でも同じ `check` を回す** `[推奨]`。Unifield は現状 GitHub Actions がデプロイのみで lint / test を回していないので、新規プロジェクトでは PR ワークフロー化すること。

### 1.2 フォーマッタと Lint の設定を置く

`.formatter.exs` は `import_deps` と HEEx フォーマッタを必ず設定し、`inputs` に `heex` を含める。

```elixir
# .formatter.exs

[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]
```

`.credo.exs` は `mix credo gen.config` で生成して**リポジトリに置く** `[推奨]`。
設定ファイルがないとデフォルト設定になり、チェック内容がバージョンによって変わる。

### 1.3 実装前に既存パターンを探す `[必須]`

新しいモジュールを書く前に、**Grep で同種の実装を探し、そのパターンに合わせる**。
本書のルールは「既存コードから抽出したもの」であり、コードと本書が食い違ったらコードを正とするか本書を更新する。

---

## 2. レイヤリングとディレクトリ構成

### 2.1 ドメイン層は Context + スキーマの2層だけ `[必須]`

サービス層・リポジトリ層・ユースケース層を作らない。

```
lib/{app}/
├── field_reports.ex              # Context（公開 API）
└── field_reports/
    ├── field_report.ex           # 集約ルートのスキーマ
    ├── field_report_expense.ex   # 子エンティティ
    └── field_report_review.ex    # 子エンティティ
```

- **ディレクトリ = 集約単位**。Context ファイルとディレクトリは同名にする。
- **子エンティティ専用の Context を作らない** `[必須]`。`FieldReportExpense` の CRUD は `{App}.FieldReports` に置く。
- Context が肥大したら**集約単位で分割する** `[推奨]`。目安は 800 行、または1ファイルに集約が3つ以上入った時点。
  （Unifield の `lib/unifield/assign_fields.ex` は 1414 行に 6 集約が同居しており、分割対象の例）

### 2.2 Web 層はドメイン層の公開 API だけを呼ぶ `[必須]`

LiveView / Controller / Component から `Repo` を直接呼ばない。Ecto スキーマへのクエリも書かない。
必要な取得条件は Context 側に関数として足す。

### 2.3 横断ユーティリティは `utils/` に置く

```
lib/{app}/utils/
├── calc.ex               # 金額計算
├── convert_datetime.ex   # タイムゾーン変換
├── logger.ex             # 構造化ログのラッパー
└── gcs.ex                # 外部ストレージ
```

状態を持たない関数モジュールにする（GenServer にしない）。

### 2.4 ファイル命名規則

| 種別 | 命名 | 例 |
|------|------|-----|
| Context | `snake_case.ex`（複数形） | `field_reports.ex` |
| Ecto スキーマ | `snake_case.ex`（**単数形**） | `field_reports/field_report.ex` |
| LiveView 一覧 | `index.ex` | `field_report_live/index.ex` |
| LiveView 詳細 | `show.ex` | `field_report_live/show.ex` |
| LiveView フォーム | `form.ex` | `field_report_live/form.ex` |
| コンポーネント | `*_components.ex` | `card_components.ex` |
| Context テスト | `snake_case_test.exs` | `field_reports_test.exs` |
| フィクスチャ | `snake_case_fixtures.ex` | `field_reports_fixtures.ex` |
| マイグレーション | `{timestamp}_{動詞_対象}.exs` | `20260115053602_create_field_reports.exs` |

ロール別に UI が分かれる場合はサブディレクトリで分ける。

```
field_report_live/
├── admin/     # 管理者向け（/management/field_reports/*）
└── worker/    # 担当者向け（/field_reports/*）
```

---

## 3. モジュール共通の書き方

### 3.1 `@moduledoc` の方針

| 対象 | `@moduledoc` |
|------|-------------|
| Context | `"The Xxx context."`（ジェネレータ生成のまま） |
| Ecto スキーマ | `false`（説明は Context 側に書く） |
| Utils | 日本語1行「〜するモジュールです。」 |
| コンポーネント | 日本語1行「カードコンポーネント」 |
| LiveView | `false` |
| Plug | 日本語で「**誰がアクセスできるか**」を書く |

### 3.2 alias の並べ方 `[推奨]`

ドメイン層は固定順。`Multi` を使わないファイルでも並びは崩さない。

```elixir
defmodule {App}.Fields do
  @moduledoc """
  The Fields context.
  """

  import Ecto.Query, warn: false
  alias {App}.Repo
  alias Ecto.Multi

  alias {App}.Fields.Field
  alias {App}.Fields.FieldTool

  alias {App}.Utils.Gcs
```

- **1行1モジュール**。`alias {App}.Fields.{Field, FieldTool}` のまとめ形式は使わない。
- スキーマ群 → 空行 → `{App}.Utils.*` の順。

### 3.3 `@spec` / `@type` は書かない `[必須]`

本書のプロジェクトでは **typespec を一切使わない**。Dialyzer を CI に入れていない状態で `@spec` を書くと、
検証されない嘘のドキュメントになり、リファクタ時に腐るため。

代わりに、**入力の制約はパターンマッチとガードで表現する**。

```elixir
# lib/unifield/accounts.ex

# ① 構造体パターンマッチで受け取る型を宣言する
def update_field(%Field{} = field, attrs) do
  field |> Field.changeset(attrs) |> Repo.update()
end

# ② ID はバイナリサイズガードで検証し、不正値はフォールバック節で nil にする
def get_user(<<_::208>> = user_id) do
  User |> Repo.get(user_id) |> Repo.preload(:remuneration_amount)
end

def get_user(_user_id), do: nil
```

`<<_::208>>` は **ULID（26文字 = 208bit）前提**。UUID v4 文字列なら `<<_::288>>`、
`:binary_id` のバイナリ表現なら `<<_::128>>` に読み替える。

> 新規プロジェクトで Dialyzer を CI に組み込むなら、公開 API に `@spec` を付ける方針に切り替えてよい。
> ただし「一部だけ付ける」は最悪なので、チームでどちらかに統一すること。

---

## 4. ドメイン層 — Context

### 4.1 関数の命名規則 `[必須]`

| 用途 | 命名 | 例 |
|------|------|-----|
| 全件取得（ページネーションなし） | `all_{複数形}/0..1` | `all_fields()` |
| 一覧（ページネーションあり） | `list_{複数形}/1` | `list_fields(params)` |
| 絞り込み一覧 | `list_{複数形}_by_{条件}/2..3` | `list_field_reports_by_user(user_id, params)` |
| 単件取得（無ければ例外） | `get_{単数}!/1` | `get_field!(id)` |
| 単件取得（無ければ nil） | `get_{単数}/1`, `get_{単数}_by_{条件}/2` | `get_invoice_by_user(id, user_id)` |
| 作成 | `create_{単数}/1..2` | `create_field(attrs)` |
| 更新 | `update_{単数}/2` | `update_field(field, attrs)` |
| 削除 | `delete_{単数}/1` | `delete_field(field)` |
| changeset 取得 | `change_{単数}/1..2` | `change_field(field)` |
| 複合更新（Multi） | `upsert_{単数}/2..3` | `upsert_field(field, attrs, locations)` |
| 状態遷移 | `{動詞}_{単数}/1..2` | `archive_field(field)`, `approve_assign_field_user(afu)` |
| 集計 | `sum_{対象}/1..2` | `sum_expenses(field_report_id)` |

状態遷移は CRUD 名に押し込めず、**業務上の動詞**で命名する。DB 上は update でも関数名は `archive_` / `approve_` / `cancel_` にする。

### 4.2 引数の順序 `[必須]`

```
(構造体 or スコープID, ドメイン値..., params \\ %{})
```

- 更新・削除系は**構造体を第1引数**にし、パターンマッチを付ける（`def update_field(%Field{} = field, attrs)`）。
- Web から来た `params`（**文字列キーの map**）は常に最後で、`\\ %{}` のデフォルトを付ける。
- Context は params を**文字列キーのまま受け取る**。atom キーへの変換はしない（atom leak を避けるため）。

### 4.3 戻り値の契約 `[必須]`

| 関数 | 戻り値 |
|------|-------|
| `create_*` / `update_*` / `delete_*` | `{:ok, %Schema{}} \| {:error, %Ecto.Changeset{}}` |
| `list_*` | `%Scrivener.Page{}` |
| `all_*` | `[%Schema{}]` |
| `get_*!` | `%Schema{}` または `Ecto.NoResultsError` |
| `get_*` | `%Schema{} \| nil` |
| Multi 系 | `{:ok, %{step => value}} \| {:error, step, value, changes}` |
| `update_all` 系 | `{count, nil}` |

`Repo.insert/update/delete` の戻り値を**そのまま返す**。独自のタプルに包み直さない。

Multi 系は **ステップ名がそのまま呼び出し側の API になる**ので、`@doc` に戻りマップを例示する。

````elixir
# lib/unifield/fields.ex

@doc """
現場の資料をストレージにアップロードし field_documents レコードを作成します。

```elixir
iex> create_field_document(%Field{}, %{path: path, client_name: name, client_type: type})
{:ok, %{field_document: field_document, upload_field_document: filename}}
```
"""
````

### 4.4 `@doc` の書き方

- **公開関数には原則すべて `@doc` を付ける** `[必須]`。
- 手書きの関数は**日本語**で説明する。
- ジェネレータが生成した英語の `## Examples` + `iex>` はそのまま残してよい（書き直さない）。
- `list_*` には `## params` 節でクエリパラメータを列挙する `[必須]`。

```elixir
# lib/unifield/fields.ex

@doc """
ページネーションに対応したfieldを取得します。

## params
- `value` 検索ワード（現場名、現場住所または名称、集合場所住所または名称）
- `page` ページ番号
- `page_size` 取得するデータ数
"""
def list_fields(params \\ %{}) do
```

---

## 5. Ecto スキーマ

### 5.1 共通スキーママクロを必ず経由する `[必須]`

**`use Ecto.Schema` を直書きしない。** 主キー戦略とタイムスタンプ型を1箇所に集約する。

```elixir
# lib/{app}/schema.ex

defmodule {App}.Schema do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.ULID, autogenerate: true}
      @foreign_key_type Ecto.ULID
    end
  end
end
```

主キーが UUID なら `Ecto.UUID` に差し替えるだけで全スキーマに反映される。これが直書きを禁止する理由。
アプリ側で ID を先に生成する場合は `Ecto.ULID.generate()` を使う。

### 5.2 スキーマ定義の順序と書式 `[必須]`

```elixir
# lib/{app}/fields/field.ex

defmodule {App}.Fields.Field do
  @moduledoc false
  use {App}.Schema
  import Ecto.Changeset

  alias {App}.Organizations.Organization
  alias {App}.Tools.Tool

  schema "fields" do
    field :name, :string
    field :field_address, :string
    field :archived_at, :utc_datetime

    belongs_to(:organization, Organization)

    many_to_many(:tools, Tool, join_through: "fields_tools")
    has_many(:field_documents, FieldDocument)

    timestamps(type: :utc_datetime)
  end
```

1. `@moduledoc false` → `use {App}.Schema` → `import Ecto.Changeset` → alias 群
2. 機微情報を持つスキーマは `schema` の直前に `@derive {Inspect, only: [...]}`
3. `schema` ブロック内の順序: **スカラー `field` → 仮想 `field` → `belongs_to` → `has_many` / `has_one` / `many_to_many` → `timestamps`**
4. 書式: **`field` はカッコなし、関連（`belongs_to` 等）はカッコあり**
5. タイムスタンプは `timestamps(type: :utc_datetime)` で統一。履歴系で更新日時が不要なら `updated_at: false`

### 5.3 列挙は `Ecto.Enum` を使う `[必須]`

文字列や整数を直接持たない。DB のカラム型は `:string`。

```elixir
field :role, Ecto.Enum, values: ~w(admin manager worker)a, default: :worker

field :check_out_status, Ecto.Enum,
  values: [:with_expense, :without_expense, :settled_separately],
  default: :with_expense
```

値の妥当性検証は `Ecto.Enum.values/2` を使って重複定義を避ける。

```elixir
validate_inclusion(cs, :work_type, Ecto.Enum.values(__MODULE__, :work_type),
  message: "作業種別を選択してください"
)
```

### 5.4 機微フィールドは二重に隠す `[必須]`

```elixir
# lib/unifield/accounts/user.ex

@derive {Inspect, only: [:id, :email, :name]}
schema "users" do
  field :password, :string, virtual: true, redact: true
  field :hashed_password, :string, redact: true
  field :current_password, :string, virtual: true, redact: true
```

- `redact: true` … Ecto の `redact_fields` に載り、監査ログの除外処理が自動で拾う
- `@derive {Inspect, only: [...]}` … `IO.inspect` / エラーレポートへの漏洩を防ぐ

**両方付ける。** どちらか一方では漏れる経路が残る。

### 5.5 changeset の命名 `[必須]`

| 用途 | 命名 |
|------|------|
| 既定 | `changeset/2`（`@doc false`） |
| オプション分岐あり | `changeset/3`（`opts \\ []`） |
| 用途別 | `{動詞}_changeset/2` |

用途別の例: `archived_changeset` / `restoration_changeset` / `approve_changeset` / `cancel_changeset` /
`registration_changeset` / `email_changeset` / `password_changeset` / `confirm_changeset`

### 5.6 バリデーションの書き方 `[必須]`

**1フィールド = 1 `validate_required` + ユーザー向けメッセージ。**
まとめて `validate_required([:a, :b, :c])` すると、どのフィールドのエラーか文言で区別できない。

```elixir
# lib/unifield/fields/field.ex

@doc false
def changeset(field, attrs) do
  field
  |> cast(attrs, [:name, :field_address, :pin_field_address, :organization_id])
  |> validate_required(:name, message: "現場名を入力してください")
  |> validate_required(:field_address, message: "現場住所または名称を入力してください")
  |> validate_required(:organization_id, message: "会社を選択してください")
end
```

複雑な検証は `defp validate_*/1` に切り出してパイプで合成する。

- **private 関数内の changeset 変数名は `cs`** で統一する
- `put_change` だけをする関数も `validate_` 接頭辞にそろえる（パイプの見た目を統一するため）

```elixir
# lib/unifield/prev_invoices/prev_invoice.ex

def changeset(prev_invoice, attrs) do
  prev_invoice
  |> cast(attrs, [:billing_year, :billing_month, :issue_at, :tax_rate, :user_id, :billing_date])
  |> validate_required(:user_id)
  |> validate_billing_date()
  |> validate_issue_at()
  |> validate_billing_year_and_month()
end

defp validate_issue_at(cs) do
  current_at = DateTime.truncate(DateTime.utc_now(), :second)
  put_change(cs, :issue_at, current_at)
end
```

オプションによる分岐は `Keyword.get/3` で受ける。

```elixir
def changeset(field_report_review, attrs, opts \\ []) do
  field_report_review
  |> cast(attrs, [:result, :description])
  |> validate_description(opts)
end

defp validate_description(cs, opts) do
  if Keyword.get(opts, :description, false) do
    validate_required(cs, :description, message: "差し戻し理由を入力してください")
  else
    cs
  end
end
```

### 5.7 一意制約は2つセットで書く `[必須]`

`unique_constraint` だけだと**フォーム送信するまでエラーが出ない**。
`unsafe_validate_unique` だけだと**競合時に DB 例外が漏れる**。両方を、同じ `error_key`・同じメッセージで書く。

```elixir
# lib/{app}/prev_invoices/prev_invoice.ex

|> unique_constraint([:billing_year, :billing_month, :user_id],
  error_key: :billing_date,
  message: "指定した請求月の請求書は作成されています。"
)
|> unsafe_validate_unique([:billing_year, :billing_month, :user_id], {App}.Repo,
  error_key: :billing_date,
  message: "指定した請求月の請求書は作成されています。"
)
```

DB 側にも対応する `unique_index` を必ず作る（[§14](#14-マイグレーション) 参照）。

### 5.8 `cast_assoc` / `put_assoc` は使わない `[必須]`

関連レコードの保存は `Ecto.Multi` で明示的に行う（[§7](#7-トランザクションとエラーハンドリング)）。

理由: `cast_assoc` は挿入・更新・削除がパラメータの形に暗黙に依存し、
「何件消えて何件入ったか」がコードから読めない。監査ログや権限チェックを挟む余地もなくなる。

---

## 6. クエリ

### 6.1 スタイルの使い分け `[推奨]`

**単純〜中程度はスキーマから始めるパイプ。**

```elixir
def list_fields(params \\ %{}) do
  from(f in Field, as: :field)
  |> search_value_query(params)
  |> order_by([f], asc: f.inserted_at)
  |> preload([f], [:tools, :field_documents, :organization])
  |> Repo.paginate(params)
end
```

**多段 join / subquery / select map を含む複雑なクエリは `from(...)` キーワード構文を `query` 変数に束ねる。**
条件は `where:` を複数行に分けて1条件ずつ書く（後から条件を足し引きしやすい）。

```elixir
query =
  from(fr in FieldReport,
    join: afu in assoc(fr, :assign_field_user),
    join: af in assoc(afu, :assign_field),
    where: afu.user_id == ^user_id,
    where: is_nil(af.canceled_at),
    order_by: [desc: af.work_at],
    preload: [assign_field_user: {afu, assign_field: af}]
  )

Repo.all(query)
```

### 6.2 クエリビルダは query を受けて query を返す `[必須]`

絞り込みは `defp {名前}_query(query, params)` に切り出す。**この中で `Repo` を呼んではいけない。**

```elixir
# lib/unifield/fields.ex

defp search_value_query(query, params) do
  value = Map.get(params, "value", "")

  if String.length(value) > 0 do
    value = "%#{value}%"

    where(
      query,
      [f],
      like(f.name, ^value) or like(f.field_address, ^value) or
        exists(
          from(l in FieldLocation,
            where: l.field_id == parent_as(:field).id and like(l.address, ^value)
          )
        )
    )
  else
    where(query, [f], is_nil(f.archived_at))
  end
end
```

- 名前は役割で揃える（`search_value_query` / `*_filter_date_query`）。
- 相関サブクエリは名前付きバインディング（`from(f in Field, as: :field)`）+ `parent_as/1` で書く。

### 6.3 `Repo` はパイプの最終行だけ `[必須]`

```elixir
# OK
Field
|> where([f], is_nil(f.archived_at))
|> preload([:organization])
|> Repo.all()

# NG: 途中で Repo を呼ぶと合成できなくなる
fields = Repo.all(Field)
Enum.filter(fields, &is_nil(&1.archived_at))
```

`Repo` を呼んでよいのは Context と `utils/` のみ。
例外は changeset 内の `unsafe_validate_unique(cs, [...], {App}.Repo, ...)`。

### 6.4 `preload` の使い分け

| 場面 | 書き方 |
|------|-------|
| 一覧クエリ | クエリ内で `preload`（1クエリに畳まれる） |
| `get_*!` | `Repo.get!(Schema, id) \|> Repo.preload([...])` の2段 |
| ネスト | キーワードリストで表現 |

```elixir
def get_field!(id) do
  Field
  |> Repo.get!(id)
  |> Repo.preload([:organization, :tools, :field_documents])
end
```

ネストの例:

```elixir
preload(assign_field_user: [[assign_field: :field], :assign_field_user_add_amounts, :user])
```

`has_one` に順序が必要なら `preload_order:` をスキーマ側に書く。

```elixir
has_one(:driver_license, DriverLicense, preload_order: [desc: :validity_date])
```

### 6.5 ページネーション

`Repo` に既定のページサイズを1箇所で設定する。

```elixir
# lib/{app}/repo.ex

defmodule {App}.Repo do
  use Ecto.Repo,
    otp_app: :{app},
    adapter: Ecto.Adapters.Postgres

  use Scrivener, page_size: 10
end
```

Context は Web から来た**文字列キーの params をそのまま受け取り**、最後に丸ごと `Repo.paginate/1` へ渡す
（`"page"` / `"page_size"` は Scrivener が解釈する）。呼び出し側でページ番号を取り出して組み替えない。

### 6.6 禁止事項 `[必須]`

- **文字列連結による SQL 組み立て**（SQL インジェクション）。必ず Ecto のクエリ API とピン演算子 `^` を使う。
- **同一サブクエリのコピー&ペースト**。2回目に書きたくなったら `defp {名前}_query/0..2` に切り出す。
  （Unifield では「最新レビュー取得」のサブクエリが `field_reports.ex` / `invoices.ex` / `assign_fields.ex` の
  計 10 箇所に重複しており、この違反の実例になっている）
- **N+1**。一覧で関連を表示するなら必ず `preload` する。

---

## 7. トランザクションとエラーハンドリング

### 7.1 複数テーブルへの書き込みは `Ecto.Multi` `[必須]`

```elixir
Multi.new()
|> Multi.delete_all(:delete_fields_tools, where(FieldTool, [ft], ft.field_id == ^field.id))
|> Multi.insert_all(:insert_fields_tools, FieldTool, fn _ -> rows end)
|> Repo.transact()
```

`Repo.transact/1`（Ecto 3.13+）を使う。`Repo.transaction/1` は既存コードの互換のためだけに残す。

### 7.2 外部 I/O は `Multi.run` に入れる `[必須]`

ファイルアップロードなどの副作用を**トランザクションの外**で行うと、DB は成功・ファイルは失敗という不整合が残る。
`Multi.run` に入れ、**失敗時はユーザー向けメッセージを持つ `{:error, "..."}` を返してロールバックさせる**。

```elixir
# lib/unifield/fields.ex

Multi.new()
|> Multi.insert(:field_document, fn _ ->
  FieldDocument.changeset(%FieldDocument{}, params)
end)
|> Multi.run(:upload_field_document, fn _repo, %{field_document: field_document} ->
  filename = get_path(field_document)

  case Gcs.upload(field_document_path.path, filename, field_document_path.client_type) do
    {:ok, _gcp_obj} ->
      {:ok, field_document.filename}

    {:error, _} ->
      {:error, "添付ファイルのアップロードに失敗しました。"}
  end
end)
|> Repo.transact()
```

### 7.3 可変個のレコードは `Enum.reduce` で Multi を積む `[必須]`

件数が実行時に決まる upsert は、`Enum.reduce` で Multi を組み立て、**ステップ名を `"name_#{id}"` で動的生成**する
（atom を動的生成すると atom テーブルが溢れるので、ステップ名は文字列にする）。

```elixir
# lib/unifield/fields.ex

def upsert_field(field, field_attrs, location_attr_set) do
  multi = Multi.insert_or_update(Multi.new(), :field, Field.changeset(field, field_attrs))

  location_attr_set
  |> Enum.reduce(multi, fn %{id: id, location: location, params: params}, prev_multi ->
    Multi.insert_or_update(prev_multi, "location_#{id}", fn %{field: field} ->
      params = Map.put(params, "field_id", field.id)
      FieldLocation.changeset(location, params)
    end)
  end)
  |> Repo.transact()
end
```

### 7.4 `with` の使いどころは2つだけ `[推奨]`

`with` を「何でも繋げる道具」として使わない。使ってよいのは次の2パターン。

**① パース失敗を「条件を付けない」に落とす**

```elixir
# lib/unifield/field_reports.ex

defp list_field_reports_filter_date_query(query, params) do
  date_str = Map.get(params, "date", "")

  with {:ok, start_date} <- Date.from_iso8601(date_str <> "-01"),
       {:ok, start_at} <- NaiveDateTime.new(start_date, ~T[00:00:00]),
       end_date <- Date.end_of_month(start_date),
       {:ok, end_at} <- NaiveDateTime.new(end_date, ~T[23:59:59]) do
    where(query, [fr, afu, af, f], af.work_at >= ^start_at and af.work_at <= ^end_at)
  else
    _ ->
      query
  end
end
```

**② トークン検証などを `nil` / `:error` に潰す**

いずれも **`else` 節は `_ ->` の1本だけ**にする。失敗理由ごとに分岐したくなったら、それは `case` で書くべき処理。
2段以下なら `with` を使わず `case` で書く。

### 7.5 Multi の結果を畳むのは必要なときだけ

呼び出し側（LiveView）に `{:ok, struct}` / `{:error, changeset}` を見せたいときだけ `|> case do` で畳む。

```elixir
# lib/unifield/accounts.ex

def reset_user_password(user, attrs, opts \\ []) do
  Ecto.Multi.new()
  |> Ecto.Multi.update(:user, User.password_changeset(user, attrs, opts))
  |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
  |> Repo.transaction()
  |> case do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, :user, changeset, _} -> {:error, changeset}
  end
end
```

それ以外は Multi の生の結果をそのまま返し、`@doc` にステップ名を明記する（[§4.3](#43-戻り値の契約-必須)）。

---

## 8. Web 層 — ルーティング

### 8.1 pipeline はレイアウト単位で切る `[推奨]`

plug の列は共通にし、**違いを `put_root_layout` と末尾の認可 plug だけ**にする。

```elixir
# lib/unifield_web/router.ex

pipeline :auth_browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {UnifieldWeb.Layouts, :auth}     # ← レイアウトだけが違う
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user
end

pipeline :admin_browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {UnifieldWeb.Layouts, :admin}    # ← レイアウトだけが違う
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user
end

pipeline :invoice_browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {UnifieldWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user
  plug :require_authenticated_user
  plug UnifieldWeb.Plugs.PrevInvoice                            # ← 認可 plug を末尾に足す
end
```

### 8.2 scope → live_session → ネスト scope `[必須]`

```elixir
scope "/", {AppWeb} do
  pipe_through [:auth_browser, :require_authenticated_user]

  live_session :require_authenticated_user,
    on_mount: [{{AppWeb}.UserAuth, :ensure_authenticated}] do

    scope "/field_reports", FieldReportLive.Worker do
      live "/", Index, :index
      live "/new_select_reports", NewSelectReport, :select
      live "/new/:assign_field_id", Confirm, :new
      live "/:id/expenses", Expense, :form
      live "/:id", Show, :show          # ← :id のルートは最後
    end
  end
end
```

- **`live_session` の名前は認可 plug の名前と一致させる**（対応関係を目で追えるようにする）。
- リソースごとに `scope "/xxx", XxxLive` でネストしてモジュール名を短縮する。
- **具体パスを先、`:id` を含むパスを最後**に並べる。

### 8.3 認可は plug と on_mount の両方に揃える `[必須]`

pipeline の plug は**最初の HTTP リクエストにしか効かない**。
LiveView 間の `push_navigate` は WebSocket 上で `on_mount` しか通らないため、
**`live_session` の `on_mount` にも同じ強さの認可フックを指定する**。

```elixir
# NG: plug は管理者チェックをするが on_mount は認証チェックのみ
#     → LiveView 遷移では管理者判定が効かない
scope "/management", {AppWeb} do
  pipe_through [:admin_browser, :require_authenticated_admin_user]

  live_session :require_authenticated_admin_user,
    on_mount: [{{AppWeb}.UserAuth, :ensure_authenticated}] do

# OK
  live_session :require_authenticated_admin_user,
    on_mount: [{{AppWeb}.UserAuth, :ensure_authenticated_admin}] do
```

> Unifield の `lib/unifield_web/router.ex` は現状 NG 側になっている（`:ensure_authenticated_admin` が
> `user_auth.ex` に定義済みだが router から使われていない）。

### 8.4 URL 設計

| 画面種別 | パターン | 例 |
|---------|---------|-----|
| 一般ユーザー向け | `/{resources}` | `/field_reports` |
| 管理者向け | `/management/{resources}` | `/management/field_reports` |
| 認証系 | `/users/{action}` | `/users/log_in` |

`live_action` は用途を表す atom にする（`:index` / `:show` / `:new` / `:edit` / `:confirm` / `:select` / `:upload`）。
同一モジュールを複数の `live_action` で共有してよい（一般用 `:index` と管理者用 `:admin_index` など）。

---

## 9. Web 層 — LiveView

### 9.1 モジュール冒頭は alias の3ブロック `[推奨]`

```elixir
# lib/{app}_web/live/organization_live/index.ex

defmodule {AppWeb}.OrganizationLive.Index do
  use {AppWeb}, :live_view

  alias {App}.Organizations          # ① Context

  alias {App}.Utils.FormatStr        # ② Utils

  # Components                       # ③ この行コメントを必ず付ける
  alias {AppWeb}.PaginationComponents, as: Pagination
  alias {AppWeb}.SearchComponents, as: Search
  alias {AppWeb}.CardComponents, as: Card
  alias {AppWeb}.BaseComponents, as: Base
```

**コンポーネントの短縮名（`as:`）はプロジェクト全体で統一する** `[必須]`。
同じモジュールをファイルごとに違う名前で呼ばない。

### 9.2 コールバックの順序 `[必須]`

```
render（定義する場合のみ） → mount → handle_info → handle_event → private 関数
```

`@impl true` は**各コールバック群の先頭の節にだけ**付ける（2節目以降には付けない）。

```elixir
# lib/unifield_web/live/organization_live/index.ex

@impl true
def handle_event("search_reset", _params, socket) do
  {:noreply, assign(socket, :value, nil)}
end

def handle_event("select_page_size", %{"page_size" => page_size}, socket) do
  redirect_path =
    format_endpoint(socket.assigns.organizations.page_number, page_size, socket.assigns.value)

  {:noreply, redirect(socket, to: redirect_path)}
end
```

### 9.3 mount はパイプで assign を積む `[必須]`

```elixir
@impl true
def mount(params, _session, socket) do
  socket =
    socket
    |> assign(:organizations, Organizations.list_organizations(params))
    |> assign(:params, params)
    |> assign(:value, params["value"])
    |> assign(:page_title, "会社一覧")

  {:ok, socket}
end
```

- `assign/3` を1キーずつパイプでつなぐ。`assign(socket, a: 1, b: 2)` のキーワード一括形式は使わない。
- **`:page_title` を必ず assign する** `[必須]`。レイアウトの `<.live_title>` と監査ログの `page` 項目が参照する。
  詳細画面は `"現場報告レビュー - #{user.name}"` のように対象名を `-` で添える。
- 最後に `{:ok, socket}` を1箇所で返す。

### 9.4 `handle_params` ではなく `apply_action` を使う `[推奨]`

`live_action` による分岐は `handle_params/3` ではなく、**mount から呼ぶ `defp apply_action/3`** に書く。

```elixir
# lib/unifield_web/live/prev_invoice_live/index.ex

@impl true
def mount(params, _session, socket) do
  socket =
    socket
    |> apply_action(socket.assigns.live_action, params)
    |> assign(:date, params["date"])

  {:ok, socket}
end

defp apply_action(socket, :index, params) do
  socket
  |> assign(:invoices, PrevInvoices.list_invoice_by_user(socket.assigns.current_user.id, params))
  |> assign(:page_title, "請求書一覧")
  |> assign(:action, ~p"/prev_invoices")
end

defp apply_action(socket, :admin_index, %{"user_id" => user_id} = params) do
  user = Accounts.get_user!(user_id)

  socket
  |> assign(:invoices, PrevInvoices.list_invoice_by_user(user.id, params))
  |> assign(:page_title, "請求書一覧 - #{user.name}")
  |> assign(:user, user)
  |> assign(:action, ~p"/management/prev_invoices/#{user_id}")
end
```

`handle_params/3` を書くのは、接続確立後（`connected?(socket)`）にだけ実行したい処理がある場合に限る。

### 9.5 テンプレートの置き場所 `[推奨]`

| 画面 | 置き場所 |
|------|---------|
| Index / Show | `xxx.html.heex` に分離 |
| Form / Upload / 認証系 | モジュール内の `def render/1` |

判断基準は分量。単一フォームで完結するならモジュール内に置いたほうが assign との対応を追いやすい。

### 9.6 行アクションのイベント名はプレフィックスマッチ `[推奨]`

一覧の各行から ID 付きのイベントを送るときは `phx-value-*` ではなく、イベント名に ID を埋めてマッチする。

```heex
<button phx-click={JS.push("archive_#{organization.id}")}>削除</button>
```

```elixir
# lib/unifield_web/live/organization_live/index.ex

def handle_event("archive_" <> id, _params, socket) do
  organization = Organizations.get_organization!(id)
  {:ok, organization} = Organizations.archive_organization(organization)
  OperationLog.info(socket, "会社をアーカイブしました。", :update, organization)

  redirect_path =
    format_endpoint(
      socket.assigns.organizations.page_number,
      socket.assigns.organizations.page_size,
      socket.assigns.value
    )

  socket =
    socket
    |> put_flash(:info, "#{organization.name}を削除しました。")
    |> push_navigate(to: redirect_path)

  {:noreply, socket}
end
```

### 9.7 画面遷移は `push_navigate` に一本化 `[必須]`

| API | 使う場面 |
|-----|---------|
| `push_navigate/2` | LiveView 間の遷移（**既定**） |
| `redirect(socket, to: ...)` | クエリパラメータだけを変えてフル再マウントさせたいとき（ページング・表示件数） |
| `push_patch/2` | **使わない**（`handle_params` を使わない設計のため） |

URL の組み立ては `defp format_endpoint/3` に切り出す。

```elixir
defp format_endpoint(page, size, value) do
  ~p"/management/organizations?page=#{page}&page_size=#{size}&value=#{value || ""}"
end
```

パスは必ず `~p` sigil（Verified Routes）で書く。文字列連結でパスを作らない `[必須]`。

### 9.8 flash は3分岐 `[必須]`

| 結果 | 扱い |
|------|------|
| 成功 | `put_flash(:info, "...")` + `push_navigate` |
| changeset エラー | **flash を出さず** `assign(form: to_form(cs))` だけ（エラーはフォームに出る） |
| 業務エラー | `put_flash(:error, "...")` のみ（遷移しない） |

```elixir
# lib/unifield_web/live/organization_live/form.ex

defp save_organization(socket, :edit, organization_params) do
  case Organizations.update_organization(socket.assigns.organization, organization_params) do
    {:ok, organization} ->
      OperationLog.info(socket, "会社を更新しました。", :update, organization)

      socket
      |> put_flash(:info, "会社情報を変更しました。")
      |> push_navigate(to: ~p"/management/organizations")

    {:error, %Ecto.Changeset{} = cs} ->
      assign(socket, form: to_form(cs))
  end
end
```

- flash の kind は **`:info` と `:error` の2種のみ**。
- `handle_event` の中では socket を組み立て切って、**最後の1箇所で `{:noreply, socket}` を返す**。
  途中で複数回 return する書き方をしない。
- flash の表示はレイアウトの `<.flash_group flash={@flash} />` 1箇所に集約する。

### 9.9 重い処理は Task + handle_info `[推奨]`

外部 API 呼び出しやアップロードで LiveView をブロックしない。

```elixir
# lib/unifield_web/live/driver_license_live/upload.ex

def handle_event("save", %{"driver_license" => params}, socket) do
  # アップロードされたファイルは {:postpone, _} で「下見」だけしておき、まだ消費しない
  front_side_path =
    socket
    |> consume_uploaded_entries(:front_side_image, fn %{path: path}, entry ->
      {:postpone, %{path: path, client_name: entry.client_name, client_type: entry.client_type}}
    end)
    |> List.first()

  cs = DriverLicenses.change_driver_license(%DriverLicense{}, params)
  pid = self()

  socket =
    if front_side_path && back_side_path && cs.valid? do
      Task.start(fn ->
        result =
          DriverLicenses.create_driver_license(
            socket.assigns.current_user.id,
            Map.get(params, "validity_date"),
            front_side_path,
            back_side_path
          )

        send(pid, {:inserted_and_uploaded, result})
      end)

      assign(socket, :is_upload, true)          # ← 二重送信を防ぐためボタンを disable にする
    else
      socket
      |> assign_form(Map.put(cs, :action, :insert))
      |> put_flash(:error, "運転免許証の画像を選択してください。また、有効期限を正しく入力してください。")
    end

  {:noreply, socket}
end

@impl true
def handle_info({:inserted_and_uploaded, {:ok, result}}, socket) do
  # 監査ログは Task の中ではなくここで出す
  OperationLog.info(socket, "免許証を登録しました。", :create, result)

  # 成功が確定してから画像のエントリーを消費する
  consume_uploaded_entries(socket, :front_side_image, fn %{path: path}, _entry -> {:ok, path} end)

  socket =
    socket
    |> put_flash(:info, "運転免許証画像のアップロードとデータ登録が完了しました。")
    |> push_navigate(to: ~p"/mypage")

  {:noreply, socket}
end

def handle_info({:inserted_and_uploaded, {:error, :front_side_image, _, _}}, socket) do
  {:noreply, put_flash(socket, :error, "運転免許証 表面の画像のアップロードに失敗しました。")}
end

def handle_info({:inserted_and_uploaded, {:error, :driver_license, cs, _}}, socket) do
  socket =
    socket
    |> assign_form(cs)
    |> put_flash(:error, "運転免許証情報の登録に失敗しました。")

  {:noreply, socket}
end
```

`consume_uploaded_entries` を `{:postpone, _}` で下見 → 成功後に改めて消費する2段構えにする。
先に消費してしまうと、DB 書き込みが失敗したときに一時ファイルが失われて復旧できない。

**監査ログは `Task` の中では出さない**（別プロセスなので `socket` の情報が取れない）。
結果を受け取る `handle_info` の成功節で出す。

### 9.10 使っていない機能

本プロジェクトでは `stream` / `live_component` / `push_patch` / `temporary_assigns`（認証系を除く）を使っていない。
新規実装でも**まず関数コンポーネントで書く**。`live_component` は独立した状態とイベントハンドラが必要になった時点で検討する。

---

## 10. Web 層 — コンポーネントと HEEx

### 10.1 `core_components.ex` は改変しない `[必須]`

Phoenix が生成した `core_components.ex` は**生成時のまま保持する**。
プロジェクト固有の見た目は別モジュール（`*_components.ex`）を新設して実現する。

理由: core を書き換えると Phoenix のバージョンアップ時に差分が取れなくなり、
`phx.gen.live` が生成するコードとも食い違う。

### 10.2 コンポーネントモジュールの置き場所

| 使用範囲 | 置き場所 |
|---------|---------|
| アプリ全体 | `lib/{app}_web/components/*_components.ex` |
| 特定機能のみ | `lib/{app}_web/live/{feature}_live/*_components.ex`（コロケート） |

役割で分ける（`card_components` / `search_components` / `pagination_components` / `base_components`）。
「共通コンポーネント」という名前の巨大な1ファイルを作らない。

### 10.3 コンポーネントの定型 `[必須]`

```elixir
# lib/{app}_web/components/card_components.ex

defmodule {AppWeb}.CardComponents do
  @moduledoc """
  カードコンポーネント
  """

  use Phoenix.Component

  import {AppWeb}.CoreComponents, only: [icon: 1]

  attr :class, :string, default: ""
  attr :click, :any, default: nil, doc: "the function for handling phx-click"
  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <article
      phx-click={@click}
      class={[
        "group rounded-2xl bg-white p-5 shadow-sm ring-1 ring-zinc-200 hover:shadow-md",
        @class,
        @click && "hover:cursor-pointer"
      ]}
    >
      {render_slot(@inner_block)}
      {render_slot(@actions)}
    </article>
    """
  end
end
```

- `use {AppWeb}, :html` ではなく **`use Phoenix.Component`** を使い、
  必要な core 関数だけ `import ... only: [...]` で取り込む（依存を最小にする）。
- `attr` / `slot` は関数の直前にまとめる。順序は `attr :class` → 個別 attr → `attr :rest, :global` → `slot :inner_block` → その他 slot。
- slot にネスト属性を持たせる場合:

```elixir
slot :subtitle do
  attr :class, :string
end
# 参照: @subtitle[:class]
```

- 独自コンポーネントの `doc:` は日本語で書く。

### 10.4 呼び出しはモジュール修飾 `[必須]`

```heex
<Card.card :for={organization <- @organizations}>
  <Card.card_header>{organization.name}</Card.card_header>
</Card.card>
```

`core_components` のみ `import` 済みなので `<.header>` / `<.icon>` / `<.link>` と書ける。
それ以外は必ず `alias ... as: Card` + `<Card.card>` の形にする（どのモジュールの関数か一目で分かるようにするため）。

### 10.5 HEEx の書き方 `[必須]`

- 補間は **`{...}`**（LiveView 1.0 の記法）。`<%= %>` は使わない。
- 条件表示は **`:if={}`**、繰り返しは **`:for={}`**。
- `<%= if ... do %> ... <% else %> ... <% end %>` は **if / else の両方が必要なときだけ**使う。

```heex
<Card.card :for={organization <- @organizations} click={JS.navigate(~p"/management/organizations/#{organization}")}>
  <div :if={organization.archived_at} class="badge badge-error">削除済み</div>
</Card.card>
```

### 10.6 クラスは配列構文で組み立てる `[必須]`

```heex
class={[
  "group rounded-2xl bg-white p-5 shadow-sm ring-1 ring-zinc-200",
  @class,
  @click && "hover:cursor-pointer"
]}
```

文字列補間（`class={"base #{extra}"}`）でクラスを組み立てない。
`nil` / `false` の要素は自動で除去されるため、`&&` で条件クラスを書ける。

### 10.7 表示用の整形はコンポーネントの外でやる `[必須]`

コンポーネントは**渡された値を描画するだけ**にする。

| 処理 | 置き場所 |
|------|---------|
| 金額計算・税計算 | `{App}.Utils.Calc` / `TaxCalc` |
| 日時のタイムゾーン変換 | `{App}.Utils.ConvertDatetime` |
| 文字列整形 | `{App}.Utils.FormatStr` |
| Enum 値 ↔ 表示ラベル | `{App}.Utils.FormatSelectOptions` |
| 画面固有の表示用データ組み立て | `live/{feature}_live/{name}_view.ex` |

ステータス → ラベル + バッジクラスの変換のような画面固有のロジックは、
LiveView の private 関数で**タプルを返す**形にしてテンプレートで展開する。

```elixir
defp get_review_status(field_report) do
  reviews = field_report.field_report_reviews

  cond do
    Enum.empty?(reviews) -> {"未承認", "badge"}
    hd(reviews).result == :approved -> {"承認", "badge badge-success"}
    hd(reviews).result == :rejected -> {"差し戻し", "badge badge-error"}
  end
end
```

```heex
<% {label, badge_class} = get_review_status(field_report) %>
<div class={badge_class}>{label}</div>
```

---

## 11. 認証・認可

### 11.1 認可は3層で行う `[必須]`

| 層 | 実装 | 守る範囲 |
|----|------|---------|
| ① HTTP plug | `require_authenticated_user` / `require_authenticated_admin_user` | 最初の HTTP リクエスト |
| ② LiveView `on_mount` | router の `live_session on_mount:` | LiveView 間の遷移 |
| ③ リソース認可 | **Context のクエリに user_id を渡す** | 他人のレコードへのアクセス |

①と②は**同じ強さのチェックを両方に置く**（[§8.3](#83-認可は-plug-と-on_mount-の両方に揃える-必須)）。

### 11.2 リソース所有権チェックの定型 `[必須]`

「取得してから持ち主を比較する」のではなく、**Context のクエリに user_id を渡して nil を返させる**。

```elixir
# Context 側
def get_invoice_by_user(<<_::208>> = id, <<_::208>> = user_id) do
  Invoice
  |> where([i], i.id == ^id and i.user_id == ^user_id)
  |> Repo.one()
end

def get_invoice_by_user(_id, _user_id), do: nil
```

```elixir
# lib/unifield_web/live/invoice_live/worker/show.ex

# LiveView 側
def mount(%{"id" => invoice_id} = params, _session, socket) do
  socket =
    if invoice = Invoices.get_invoice_by_user(invoice_id, socket.assigns.current_user.id) do
      socket
      |> assign(:invoice, invoice)
      |> assign(:page_title, "請求書")
    else
      socket
      |> put_flash(:error, "不正なアクセスです。")
      |> push_navigate(to: ~p"/invoices")
    end

  {:ok, socket}
end
```

「存在しない」と「権限がない」を区別せず、**同じ応答を返す**（リソースの存在を漏らさないため）。

### 11.3 `current_user` の扱い `[必須]`

`current_user` を assign するのは次の2箇所だけ。LiveView 内でセッションから組み立て直さない。

```elixir
# lib/unifield_web/user_auth.ex

# ① plug: セッション（または remember me クッキー）から引いて assign する
def fetch_current_user(conn, _opts) do
  {user_token, conn} = ensure_user_token(conn)
  user = user_token && Accounts.get_user_by_session_token(user_token)
  assign(conn, :current_user, user)
end

# ② on_mount: assign_new なので、すでに載っていれば再取得しない
defp mount_current_user(socket, session) do
  Phoenix.Component.assign_new(socket, :current_user, fn ->
    if user_token = session["user_token"] do
      Accounts.get_user_by_session_token(user_token)
    end
  end)
end
```

### 11.4 モジュール plug の書き方

```elixir
# lib/unifield_web/plugs/invoice.ex

defmodule UnifieldWeb.Plugs.PrevInvoice do
  @moduledoc """
  請求書にアクセスできるユーザーを検証します。

  アクセスできるユーザーは管理者、編集者またはその請求者のみです。
  それ以外のユーザーはアクセスできません。
  """
  use UnifieldWeb, :controller

  alias Unifield.Accounts.User
  alias Unifield.PrevInvoices

  def init(opts), do: opts

  def call(conn, _opts) do
    prev_invoice = PrevInvoices.get_invoice!(conn.params["id"])
    current_user = conn.assigns[:current_user]

    if match?(%User{role: :admin}, current_user) || match?(%User{role: :manager}, current_user) ||
         (conn.assigns[:current_user] && prev_invoice.user_id == conn.assigns.current_user.id) do
      conn
    else
      conn
      |> redirect(to: ~p"/prev_field_reports")
      |> halt()
    end
  end
end
```

- `@moduledoc` に**誰がアクセスできるか**を書く。
- ロール判定は `match?(%User{role: :admin}, current_user)` の形に統一する（`current_user` が nil でも落ちない）。
- 拒否時は必ず `redirect |> halt()`。`halt()` を忘れると後続の plug が動く。
- **ファイル名とモジュール名を一致させる** `[必須]`
  （Unifield は `plugs/invoice.ex` に `Plugs.PrevInvoice` が入っており不一致。真似しないこと）

### 11.5 禁止事項 `[必須]`

- 平文パスワードの保存・ログ出力
- オブジェクトストレージのファイルを直 URL で公開する（**署名付き URL を使う**）
- CSRF トークンの除外（`protect_from_forgery` を外さない）
- 文字列連結による SQL
- 認可チェックをテンプレート側（`:if`）だけで行う（ボタンを隠すのは UX であって認可ではない）

---

## 12. ログと監査ログ

### 12.1 Logger はカテゴリ付きのラッパー経由にする `[推奨]`

生の `Logger` を直接使うと、ログのフォーマットとカテゴリが書き手ごとにばらつく。
**カテゴリをホワイトリスト化したマクロ**を用意し、それだけを使う。

```elixir
# lib/unifield/utils/logger.ex

defmodule Unifield.Utils.Logger do
  @moduledoc """
  Unifield用にLoggerをラッピングしたモジュールです。

  `require Logger`でElixir純正のLoggerをロードしないでください。
  """

  # カテゴリーはここで増やす
  @categories %{
    log_in: "ログイン",
    email: "メール送信",
    sms: "SMS送信",
    line: "LINE送信",
    batch: "定期実行",
    reminder: "リマインド",
    create: "作成",
    update: "更新",
    delete: "削除",
    other: "その他"
  }

  defmacro __using__(_opts) do
    quote do
      require Unifield.Utils.Logger, as: Logger
    end
  end

  # @categories に定義済みのカテゴリーだけがこの節にマッチする
  defmacro info(message, category, variables) when is_map_key(@categories, category) do
    category = @categories[category]

    quote do
      require Logger

      Logger.info(%{
        message: unquote(message),
        category: unquote(category),
        variable: unquote(variables)
      })
    end
  end

  # 未定義のカテゴリーはこちらに落ちる
  defmacro info(message, category, variables) do
    quote do
      require Logger

      Logger.info(%{
        message: unquote(message),
        category: unquote(category),
        variable: unquote(variables)
      })

      if Application.get_env(:unifield, :env) == :dev do
        raise("category: #{unquote(category)}が存在しません")
      end
    end
  end

  # error/3 も同じ形で2節を用意する
end
```

```elixir
use {App}.Utils.Logger

Logger.info("LINEの送信に成功しました。", :line, %{result: result})
Logger.error("SMSの送信に失敗しました。", :sms, %{result: result})
```

ポイント:

- `defmacro ... when is_map_key(@categories, category)` で**コンパイル時に**カテゴリを検証する。
  未定義カテゴリを渡すと開発環境で例外になる。
- 新しいカテゴリは `@categories` に追加してから使う。
- 本番は JSON 形式で出力し、メタデータに `request_id` / `remote_ip` / `mfa` / `file` / `line` を含める。
- **バッチ処理は開始と終了で必ずログを出す** `[必須]`（実行されたかどうかを後から確認できるようにする）。

### 12.2 監査ログ `[推奨]`

Web 層から create / update / delete を呼ぶときは、**「誰が・いつ・どのページで・どのデータで・何をしたか」**を1行で残す。

```elixir
OperationLog.info(socket, "会社を作成しました。", :create, organization)  # LiveView
OperationLog.info(conn, "LINEアカウントを連携しました。", :update, user)   # Controller
```

`use {AppWeb}, :live_view` / `:controller` に組み込んでおき、各モジュールでの `use` を不要にする。

| 項目 | ルール |
|------|-------|
| 出力タイミング | **書き込みが成功したときのみ**。`{:error, %Ecto.Changeset{}}` の節では出さない |
| `Task` の中 | 別プロセスなので出さない。結果を受ける `handle_info` の成功節で出す |
| カテゴリ | `:create` / `:update` / `:delete`。アーカイブ・承認・差し戻しは DB 上 update なので `:update` |
| 第4引数 | 書き込み結果の構造体・Multi の結果マップを**そのまま渡す**（呼び出し側でフィールドを選別しない） |
| 対象外 | セッショントークン・確認メールトークンなど認証プラミング系の書き込み |

メッセージは**ます形＋末尾「。」**で統一し、リソース名は用語集のユビキタス言語に揃える。
単純な CRUD でない操作は業務的な意味を書く（`"現場報告を差し戻しました。"`）。

### 12.3 機微データのマスクは呼び出し側でやらない `[必須]`

ログ出力側の `normalize/1` で自動除外する。

- Ecto スキーマの `redact: true` フィールド（`__schema__(:redact_fields)` で取得できる）
- モジュール属性の `@redact_keys`（`token` / `encode_password` など）
- 仮想フィールド・未ロードのアソシエーション・`__meta__`

`redact: true` の付いていない機微フィールドを新設したら、`@redact_keys` に追加する。
**呼び出し側で `Map.drop` する運用にしない**（必ず漏れる）。

---

## 13. 設定と秘密情報

### 13.1 秘密情報はコンパイル時 config に置かない `[必須]`

`config.exs` / `dev.exs` / `prod.exs` はコンパイル時に評価され、**リリースバイナリに焼き込まれる**。
API キー・パスワード・シークレットは必ず `runtime.exs` に置く。

開発用の DB 接続情報など、リポジトリに書いてよい値は「環境変数 || 開発用デフォルト」で書く。

```elixir
config :{app}, {App}.Repo,
  password: System.get_env("PGPASSWORD") || "postgres"
```

### 13.2 外部サービス設定は `runtime.exs` に集約する `[必須]`

**モジュール名をキーにして `System.get_env` を1箇所に閉じ込める。**

```elixir
# config/runtime.exs

# SMS
config :{app}, {App}.Utils.SmsClient, api_key: System.get_env("VONAGE_API_KEY")
config :{app}, {App}.Utils.SmsClient, api_secret: System.get_env("VONAGE_API_SECRET")
config :{app}, {App}.Utils.SmsClient, from: System.get_env("SMS_FROM")

# 税率
config :{app}, :tax_rate, System.get_env("TAX_RATE", "10")
```

- 必須値は `System.get_env("X") || raise "..."` で**起動時に落とす**（実行時に nil で謎の失敗をさせない）。
- 任意値は `System.get_env("X", "default")` でデフォルトを与える。
- `System.get_env` をアプリケーションコードから直接呼ばない `[必須]`。

### 13.3 設定値は関数経由で解決する `[必須]`

```elixir
# lib/{app}/utils/gcs.ex

# OK: 呼ばれるたびに解決する
defp bucket() do
  Application.get_env(:{app}, __MODULE__, [])[:bucket]
end

# NG: モジュール属性はコンパイル時に固定される
@bucket Application.get_env(:{app}, __MODULE__)[:bucket]
```

`__MODULE__` をキーにすることで、設定とそれを使うモジュールの対応が自明になる。

### 13.4 その他

- `config.exs` に `generators: [timestamp_type: :utc_datetime, binary_id: true]` を置き、
  `phx.gen.*` の生成物を最初からルールに沿った形にする。
- `config :{app}, :env, :prod` のような環境識別フラグを持たせ、コード側で `Mix.env()` を参照しない
  （`Mix` はリリースに含まれない）。
- prod 限定の設定は `if config_env() == :prod do ... end` にまとめる。

---

## 14. マイグレーション

### 14.1 命名

`{timestamp}_{動詞_対象}.exs`。動詞の語彙を揃える。

| 操作 | 命名 |
|------|------|
| テーブル作成 | `create_{table}` |
| カラム追加 | `add_{column}_to_{table}` |
| リネーム | `rename_{...}` |
| カラム削除 | `drop_{column}_from_{table}` |
| データ移行 | `migrate_{...}_data` |
| 初期データ投入 | `insert_default_{...}_values` |

**スキーマ変更とデータ移行を伴う変更は複数ファイルに分割する** `[推奨]`。

```
20260705000001_create_new_field_reports.exs
20260705000002_migrate_field_report_data.exs
20260705000003_drop_field_report_columns.exs
```

### 14.2 `def change` だけを使う `[必須]`

`up` / `down` を手書きせず、`change` で書く。
`change` で表現できないデータ移行は `execute/2` を使う（次項）。

### 14.3 データ移行は `execute(up, down)` の2引数形式 `[必須]`

1引数の `execute/1` を使うとロールバックできないマイグレーションになる。
戻す必要がない場合でも、ダミーの `"SELECT 1"` を渡して down を通せるようにする。

```elixir
# priv/repo/migrations/20260726005031_add_check_out_status_to_field_reports.exs

def change do
  alter table(:field_reports) do
    add :check_out_status, :string
  end

  # 既存データのバックフィル
  # 経費が1件以上ある現場報告は「経費精算あり」、0件の現場報告は「経費精算なし」とする
  execute(
    """
    UPDATE field_reports fr
    SET check_out_status = CASE
      WHEN EXISTS (
        SELECT 1 FROM field_report_expenses fre WHERE fre.field_report_id = fr.id
      ) THEN 'with_expense'
      ELSE 'without_expense'
    END
    """,
    "SELECT 1"
  )
end
```

**何のための移行かを日本語コメントで残す** `[必須]`。マイグレーションは後から読み返される。

### 14.4 テーブル定義の定型 `[必須]`

```elixir
# priv/repo/migrations/20251216135053_create_fields.exs

create table(:fields, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :name, :string
  add :archived_at, :utc_datetime
  add :organization_id, references(:organizations, on_delete: :nothing, type: :binary_id)

  timestamps(type: :utc_datetime)
end

create index(:fields, [:organization_id])
```

- PK は `primary_key: false` + `add :id, :binary_id, primary_key: true`。
- FK は `references(:table, on_delete: :nothing, type: :binary_id)` で統一する。
  **物理削除ではなく `archived_at` による論理削除を前提**にしているため `on_delete: :nothing` にする。
  必須の FK には `null: false` を付ける。
- **インデックスは `create table` ブロックの外**に書く。
- 中間テーブルは `timestamps(type: :utc_datetime, updated_at: false)` + 複合ユニークインデックス。
- `Ecto.Enum` に対応するカラムは `:string`。

### 14.5 後方互換を維持する `[必須]`

デプロイはマイグレーション → 新バージョン起動の順で行われ、
**マイグレーション実行中は旧バージョンのコードが動いている**。

- NOT NULL カラムを追加するときは `default:` を必ず指定する
- カラムのリネーム・削除は「追加 → 両方書く → 切り替え → 削除」の複数リリースに分ける

---

## 15. テスト

### 15.1 配置と命名 `[必須]`

`test/` は `lib/` をミラーする。

```
test/
├── test_helper.exs
├── support/
│   ├── data_case.ex              # Context テスト用
│   ├── conn_case.ex              # Web テスト用
│   └── fixtures/*_fixtures.ex
├── {app}/                        # ドメイン層
│   ├── field_reports_test.exs
│   └── utils/
└── {app}_web/
    ├── controllers/*_test.exs
    └── live/*_live_test.exs
```

`mix.exs` の `elixirc_paths(:test)` に `test/support` を含める。

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

### 15.2 describe / test の命名 `[必須]`

| テスト種別 | `describe` | `test` |
|-----------|-----------|--------|
| Context | **関数名/アリティ**（`"list_fields/1"`） | 日本語の説明 |
| LiveView | **画面名**（`"経費登録フォーム"`） | 「〜すると〜が表示される」形式の日本語 |

観点で分ける場合は `describe "normalize/1 機微フィールドの除外"` のように「関数/アリティ + 観点」にする。

```elixir
# test/unifield/fields_test.exs

describe "list_fields/1" do
  test "ページネーションのfieldを取得する", %{field: field} do
    assert %Scrivener.Page{} = page = Fields.list_fields()
    assert page.entries == [field]
  end
end
```

### 15.3 フィクスチャは Context の公開 API 経由 `[必須]`

`Repo.insert` で直接作らない。バリデーションを通った正しいデータだけがテストに入るようにする。

```elixir
# test/support/fixtures/fields_fixtures.ex

@doc """
Generate a field_location.

`field_id` は呼び出し側で指定してください。
"""
def field_location_fixture(attrs \\ %{}) do
  {:ok, field_location} =
    attrs
    |> Enum.into(%{
      address: "some address",
      pin_address: "some pin_address",
      label: "some label"
    })
    |> {App}.Fields.create_field_location()

  field_location
end
```

- `attrs |> Enum.into(デフォルト) |> Context.create_*()` → `{:ok, x}` を束縛して構造体を返す。
- **外部キーはデフォルトに入れない** `[必須]`。呼び出し側で指定させ、その旨を `@doc` に書く。
  （デフォルトで親を自動生成すると、テストごとに無関係なレコードが増えて意図が読めなくなる）

### 15.4 setup の書き方

3パターンを使い分ける。

```elixir
# ① 無名 setup でコンテキスト一式を組み立ててマップを返す（Context テスト）
setup do
  organization = organization_fixture(%{name: "Test"})
  field = field_fixture(%{name: "Test", organization_id: organization.id})
  field = Repo.preload(field, [:organization, :tools])

  %{organization: organization, field: field}
end

# ② 名前付き関数 + setup リスト（LiveView テスト）
defp create_field(_), do: %{field: field_fixture()}
setup [:create_field]

# ③ ConnCase のヘルパーに describe 内 setup を重ねる
setup :register_and_log_in_user
```

複雑なデータ組み立てはファイル末尾のプライベートヘルパーに切り出し、**日本語コメント**で何を作るか書く。

### 15.5 mock は外部 I/O 境界にだけ当てる `[必須]`

自分たちのモジュールを mock しない。mock してよいのは**ストレージ・HTTP クライアントなど外部サービスの境界**だけ。

**成功系と失敗系を対で書き、失敗時のロールバックまで検証する。**

```elixir
test "ファイルのアップロードが失敗した場合はロールバックする", %{field: field} do
  with_mock Gcs, upload: fn _path, _filename, _type -> {:error, "gcp object"} end do
    {:error, :upload_field_document, "添付ファイルのアップロードに失敗しました。",
     %{field_document: field_document}} =
      Fields.create_field_document(field, @field_document_path)

    refute Repo.get(FieldDocument, field_document.id)
  end
end
```

メールは mock せず、テスト用アダプタ + `assert_received {:email, mail}` / `refute_received` で検証する。

### 15.6 LiveView テストは画面と DB の両方を検証 `[必須]`

画面に文字列が出たことだけを確認して終わりにしない。**書き込みが実際に起きたかを DB 側で確認する。**

```elixir
@radio "input[type='radio'][name='check_out_status']"

test "「経費精算なし」を選ぶと現場報告が without_expense で保存される", %{conn: conn, user: user} do
  {:ok, view, _html} = live(conn, ~p"/field_reports/#{id}/check_out_status")

  assert has_element?(view, @radio)
  render_change(view, "save", %{"check_out_status" => "without_expense"})

  field_report = latest_field_report(user)
  assert field_report.check_out_status == :without_expense
end
```

- 属性・セレクタはモジュール属性に切り出す（`@create_attrs` / `@update_attrs` / `@invalid_attrs` / `@radio`）。
- リダイレクト検証は戻り値のパターンマッチ:
  `assert {:error, {:live_redirect, %{to: "/field_reports"}}} = render_click(view, "send_report")`

### 15.7 実行ポリシー

- `async` は既定 **false**（DB を共有するため）。DB に触らない純関数テストだけ `async: true` にする。
- `mix test` のエイリアスで**毎回 DB を再作成**する。

```elixir
test: ["ecto.drop --quiet", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
```

- 生成されたままで手を入れていないテストは `@describetag :skip` で**凍結する** `[推奨]`。
  コメントアウトで残さない（フォーマッタも Credo も効かなくなる）。
- プッシュ前に `make check` を通す。

---

## 16. 日時・数値・文言

### 16.1 日時は UTC で保存し、表示直前だけ変換する `[必須]`

```elixir
# NG: ローカル時刻で保存する
%FieldReport{report_at: jst_datetime}

# OK: 保存は UTC、表示のときだけ変換する
ConvertDatetime.convert(field_report.report_at, :jp)
```

- DB / Ecto の型は `:utc_datetime` で統一する。
- 変換は `{App}.Utils.ConvertDatetime` の1モジュールに閉じ込める。

```elixir
# lib/{app}/utils/convert_datetime.ex

defmodule {App}.Utils.ConvertDatetime do
  @moduledoc """
  DateTime型のデータをタイムゾーンごとの時間に変換するモジュールです。
  """

  @doc """
  タイムゾーンの時刻に変換します。
  """
  def convert(%DateTime{} = at, :jp) do
    DateTime.shift(at, hour: 9)
  end
end
```

「月初〜月末」のような期間の境界を計算するときは、**どのタイムゾーンでの境界か**を明示的に扱う。

### 16.2 金額計算は専用モジュールに集約する `[必須]`

Web 層・テンプレートに計算式を書かない。**同名関数を構造体ごとに多重定義して分岐を型で表す。**

```elixir
# lib/unifield/utils/calc.ex

def calc_subtotal(%AssignField{} = assign_field) do
  calc_subtotal(assign_field.assign_field_users) +
    calc_subtotal(assign_field.assign_field_assistant_users)
end

def calc_subtotal(assign_field_users) when is_list(assign_field_users) do
  Enum.reduce(assign_field_users, 0, fn user, total -> total + calc_subtotal(user) end)
end

def calc_subtotal(%AssignFieldAssistantUser{} = assistant_user), do: assistant_user.amount || 0
```

`nil` を受ける節（`def calc_expenses(nil), do: 0`）まで用意しておくと、呼び出し側から `if` が消える。

金額は整数（円）で扱い、浮動小数を使わない。端数処理（切り捨て / 四捨五入）の方針を1箇所に書く。

### 16.3 Enum 値と表示ラベルの対応表は1箇所に置く `[必須]`

```elixir
def work_type_options do
  Ecto.Enum.values({App}.AssignFields.AssignField, :work_type)
  |> Enum.map(fn
    :day -> {"日勤", :day}
    :night -> {"夜勤", :night}
  end)
end
```

同じ対応をテンプレートに散らさない。ラベルを変えるときの修正箇所が1つで済むようにする。

### 16.4 文言のルール `[必須]`

単一言語のアプリでは gettext を使わず、文言を直書きしてよい
（多言語対応の予定がないのに gettext を通すと、翻訳ファイルの保守コストだけが残る）。
ただし**文体と用語は統一する**。

| 対象 | ルール | 例 |
|------|-------|-----|
| 成功メッセージ | ます形 + 句点 | `"会社を作成しました。"` |
| 失敗メッセージ | ます形 + 句点 | `"現場報告の承認ができませんでした。"` / `"アップロードに失敗しました。"` |
| バリデーション | 「〜してください」 | `"現場名を入力してください"` |
| ボタンのローディング | `phx-disable-with` に必ず指定 | `phx-disable-with="登録中..."` |
| 確認ダイアログ | `data-confirm` に文章で | `data-confirm="削除しますか？"` |
| 監査ログ | ます形 + 句点（[§12.2](#122-監査ログ-推奨)） | `"現場報告を差し戻しました。"` |

- **リソース名は用語集（`docs/glossary.md`）のユビキタス言語に揃える** `[必須]`。
  コードの識別子と画面の日本語を1対1に対応させる（現場 = `field`、現場報告 = `field_report`）。
- **同じ意味の文言を揺らさない** `[必須]`。
  （Unifield には `"不正なアクセスです"` と `"不正なアクセスです。"` の揺れがある。真似しないこと）
- 日付表示は `Calendar.strftime(date, "%Y年%m月%d日")` に統一する。
- HTML の `lang` 属性を設定する（`<html lang="ja">`）。

---

## 17. 禁止事項一覧

`[必須]` のうち「やってはいけないこと」の早見表。レビュー時のチェックリストとして使う。

| # | 禁止事項 | 参照 |
|---|---------|------|
| 1 | `use Ecto.Schema` の直書き（`use {App}.Schema` を使う） | [§5.1](#51-共通スキーママクロを必ず経由する-必須) |
| 2 | `@spec` / `@type` を一部にだけ書く | [§3.3](#33-spec--type-は書かない-必須) |
| 3 | `cast_assoc` / `put_assoc` の使用 | [§5.8](#58-cast_assoc--put_assoc-は使わない-必須) |
| 4 | まとめて `validate_required([:a, :b])`（メッセージが付けられない） | [§5.6](#56-バリデーションの書き方-必須) |
| 5 | `unique_constraint` と `unsafe_validate_unique` の片方だけ | [§5.7](#57-一意制約は2つセットで書く-必須) |
| 6 | クエリビルダ（`defp *_query/2`）の中で `Repo` を呼ぶ | [§6.2](#62-クエリビルダは-query-を受けて-query-を返す-必須) |
| 7 | パイプの途中での `Repo` 呼び出し | [§6.3](#63-repo-はパイプの最終行だけ-必須) |
| 8 | 文字列連結による SQL 組み立て | [§6.6](#66-禁止事項-必須) |
| 9 | 外部 I/O をトランザクションの外で実行する | [§7.2](#72-外部-io-は-multirun-に入れる-必須) |
| 10 | Multi のステップ名を atom で動的生成する | [§7.3](#73-可変個のレコードは-enumreduce-で-multi-を積む-必須) |
| 11 | Web 層から `Repo` / Ecto スキーマを直接触る | [§2.2](#22-web-層はドメイン層の公開-api-だけを呼ぶ-必須) |
| 12 | `core_components.ex` の改変 | [§10.1](#101-core_componentsex-は改変しない-必須) |
| 13 | HEEx でクラスを文字列補間で組み立てる | [§10.6](#106-クラスは配列構文で組み立てる-必須) |
| 14 | Web 層・テンプレートに計算式を書く | [§10.7](#107-表示用の整形はコンポーネントの外でやる-必須) |
| 15 | パスを文字列連結で作る（`~p` を使う） | [§9.7](#97-画面遷移は-push_navigate-に一本化-必須) |
| 16 | 認可を plug だけ / `on_mount` だけに置く | [§8.3](#83-認可は-plug-と-on_mount-の両方に揃える-必須) |
| 17 | 平文パスワードの保存・ログ出力 | [§11.5](#115-禁止事項-必須) |
| 18 | ストレージファイルの直 URL 公開 | [§11.5](#115-禁止事項-必須) |
| 19 | 呼び出し側で機微データをマスクする運用 | [§12.3](#123-機微データのマスクは呼び出し側でやらない-必須) |
| 20 | コンパイル時 config に秘密情報を置く | [§13.1](#131-秘密情報はコンパイル時-config-に置かない-必須) |
| 21 | アプリケーションコードから直接 `System.get_env` を呼ぶ | [§13.2](#132-外部サービス設定は-runtimeexs-に集約する-必須) |
| 22 | 設定値をモジュール属性で読む | [§13.3](#133-設定値は関数経由で解決する-必須) |
| 23 | `execute/1`（ロールバックできないマイグレーション） | [§14.3](#143-データ移行は-executeup-down-の2引数形式-必須) |
| 24 | DB にローカル時刻を保存する | [§16.1](#161-日時は-utc-で保存し表示直前だけ変換する-必須) |
| 25 | フィクスチャを `Repo.insert` で直接作る | [§15.3](#153-フィクスチャは-context-の公開-api-経由-必須) |
| 26 | 自作モジュールを mock する | [§15.5](#155-mock-は外部-io-境界にだけ当てる-必須) |
| 27 | テストをコメントアウトで残す（`@describetag :skip` を使う） | [§15.7](#157-実行ポリシー) |

---

## 付録 A. 他プロジェクトへの導入チェックリスト

### A.1 置き換えが必要な箇所

| 項目 | Unifield の値 | 確認すること |
|------|--------------|-------------|
| モジュール名 | `Unifield` / `UnifieldWeb` / `:unifield` | `{App}` / `{AppWeb}` / `{app}` を置換 |
| 主キー戦略 | ULID（`Ecto.ULID`） | UUID なら `Ecto.UUID` に変更 |
| ID ガードのビット長 | `<<_::208>>`（ULID 26文字） | UUID 文字列なら `<<_::288>>` |
| タイムゾーン | JST（`DateTime.shift(at, hour: 9)`） | 対象地域に合わせる |
| ページネーション | `scrivener_ecto` | 別ライブラリなら [§6.5](#65-ページネーション) を読み替え |
| 監査ログ | `OperationLog` | 要否をプロジェクトごとに判断 |
| 文言の言語 | 日本語 | 多言語ならば gettext に切り替え（[§16.4](#164-文言のルール-必須)） |

### A.2 最初に用意するファイル

| ファイル | 目的 | 参照 |
|---------|------|------|
| `lib/{app}/schema.ex` | 主キー戦略の集約 | [§5.1](#51-共通スキーママクロを必ず経由する-必須) |
| `lib/{app}/utils/logger.ex` | カテゴリ付き Logger | [§12.1](#121-logger-はカテゴリ付きのラッパー経由にする-推奨) |
| `lib/{app}/utils/convert_datetime.ex` | タイムゾーン変換 | [§16.1](#161-日時は-utc-で保存し表示直前だけ変換する-必須) |
| `.formatter.exs` | フォーマッタ（HEEx 含む） | [§1.2](#12-フォーマッタと-lint-の設定を置く) |
| `.credo.exs` | Lint 設定 | [§1.2](#12-フォーマッタと-lint-の設定を置く) |
| `Makefile`（`check` ターゲット） | 品質ゲート | [§1.1](#11-品質ゲートを1コマンドに集約する-必須) |
| CI ワークフロー | PR で `check` を回す | [§1.1](#11-品質ゲートを1コマンドに集約する-必須) |

### A.3 既存プロジェクトへの段階的導入

一度に全部を適用しようとせず、この順で入れる。

1. **品質ゲート**（[§1](#1-基本原則)）— まず `check` が通る状態にする。以降の変更が安全になる
2. **命名規則**（[§2.4](#24-ファイル命名規則), [§4.1](#41-関数の命名規則-必須)）— 新規コードから適用
3. **Context / スキーマ**（[§4](#4-ドメイン層--context), [§5](#5-ecto-スキーマ)）— スキーママクロの導入は既存スキーマの一括置換で済む
4. **Web 層**（[§8](#8-web-層--ルーティング)〜[§11](#11-認証認可)）— 認可の抜け（[§8.3](#83-認可は-plug-と-on_mount-の両方に揃える-必須)）を最優先で潰す
5. **テスト**（[§15](#15-テスト)）— 新規テストから適用。既存テストは触らない
6. **ログ・監査ログ**（[§12](#12-ログと監査ログ)）— 最後。導入効果は大きいが既存コードへの差分も大きい
