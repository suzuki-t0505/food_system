# 要求内容: 品質ゲートの整備

- 作業日: 2026-11-03
- 位置づけ: [development-guidelines.md §1.4](../../docs/development-guidelines.md) の「段階 0: 基盤整備」のうち、品質ゲート（architecture §14 / §16 #5）のみ
- 対象アプリ: `food_vault` / `food_ship`（両方に同じ内容を入れる）

## 背景

- `Makefile` に `check`（compile → format → credo → test）はあるが、`credo` 依存と `.credo.exs` が無く `make mix_credo` が動かない
- `precommit` エイリアスに `credo` が無い
- `mix_format` は書き換え型で、未整形を検出できない（CI に不向き）
- PR で lint と test を回すワークフロー（`.github/workflows/`）が無い
- `docker-compose.yml` の `db` に healthcheck が無く、CI で起動を待てない

## 要求

| # | 要求 |
| :-- | :-- |
| R1 | 両アプリに `credo` を導入し、`mix credo --all` が実行できる |
| R2 | 各アプリに `.credo.exs` を置く。「改変しない」`core_components.ex` は検査対象から除く |
| R3 | `mix precommit` が `check` と同じ 4 つのゲート（compile 警告ゼロ・format・credo・test）を含む |
| R4 | `make check` が、未整形コードを検出して失敗する（`mix format --check-formatted`） |
| R5 | PR と `main` への push で、CI が `make check` を実行する（開発と同じコンテナ経由） |
| R6 | CI が DB の起動完了を待てる（`db` に healthcheck） |
| R7 | 永続ドキュメントの「整備予定」の記述を現状に合わせる |

## 受け入れ条件

- [ ] 両アプリで `make deps_get && make check` が通る（ユーザーがローカルで確認）
- [ ] PR で `ci.yml` が走り、緑になる
- [ ] 未整形のファイルを入れると `make check` と CI が失敗する
- [ ] `mix.lock` に credo 関連が追加されている（ユーザー側の `mix deps.get` で生成してコミット）
- [ ] architecture §14 / §16 #5、repository-structure §6.1、development-guidelines §2 の記述が実態と一致している

## 対象外

ULID（`ecto_ulid_next` の検証を含む）、`{App}.Schema`、Logger / OperationLog / Permission の雛形、認証、本番 Dockerfile

## 制約

- 実装環境に Elixir と Docker デーモンが無く、compile / format / credo / test は実行できない。`mix.lock` も更新できない
- 検証はユーザーのローカル実行と CI の初回実行で行う
