# タスクリスト: CSV 一括取込・一括再引当・一括梱包完了

- 要求: [requirements.md](requirements.md) / 設計: [design.md](design.md)
- 注: この環境には Elixir が無く、`mix` を実行できない。検証項目(`mix format`・`mix compile`・`mix test`)は実装後も未実行になるため、実行できた時点でチェックする

## 1. 解析(`CsvParser`)

- [x] `lib/food_ship/shipping_slips/csv_parser.ex`(BOM・UTF-8 検査・引用符・CRLF/LF・空行・見出し行・行数/サイズ上限・開始行番号)
- [x] `test/food_ship/shipping_slips/csv_parser_test.exs`

## 2. 検証と保存(Context)

- [x] `ShippingSlip.retryable_error?/1`(一括再引当の対象判定。`:connection`・`:idempotency_conflict`)
- [x] `ShippingSlips.build_attrs/2` に `input_source` を渡せるようにする(手入力は `"manual"` のまま)
- [x] `lib/food_ship/shipping_slips/csv_import.ex`(形式 → マスタ → ファイル内重複 → `create_changeset` の検証、行番号つきエラー、全行を 1 トランザクションでファイル順に保存)
- [x] `ShippingSlips.import_csv/2`(権限 → 倉庫 → 解析 → 検証 → 保存。戻りは引当順)
- [x] `ShippingSlips.list_reallocation_targets/0`・`list_slips_by_ids/1`
- [x] `lib/food_ship/shipping_slips/bulk.ex`(`run/4`: 与えた順に 1 件ずつ・例外でも続行・`notify`)
- [x] テスト: `import_csv/2`(正常系・検証エラーの各種・原子性・倉庫未設定・`viewer` 拒否・1,000 行の性能)、`Bulk`、対象の取得順と恒久エラーの除外

## 3. 画面

- [x] `SlipMessages`(検証エラー・一括処理の結果の要約の文言)
- [x] `SlipComponents`(`bulk_progress/1`・`bulk_results/1`)
- [x] ルーター(`/shipping_slips/import`、`staff` 以上)
- [x] `ShippingSlipLive.Import`(アップロード・検証エラー一覧・結果表の stream・進捗・`Task` ＋ monitor・操作ログ)
- [x] `ShippingSlipLive.Index`(「CSV を取り込む」リンク、「一括再引当」、行の選択と「選択した伝票を梱包完了にする」、`bulk` の状態・進捗パネル・実行中の無効化・`Task` の異常終了)
- [x] テスト: `Import`(アップロード → 結果、検証エラー、未保存、実行中の無効化、中断、`viewer`)、`Index`(一括再引当・一括梱包完了、順序、失敗した伝票が `allocated` のまま、二重実行不可、`viewer` に非表示)
- [ ] 既存テスト(`index_test.exs` など)に影響が無いことを確認

## 4. ドキュメント

- [x] `docs/product-requirements.md`(未決事項 #2 の記録、F-S5 の反映)
- [x] `docs/functional-design.md` §6.1・§6.2(文字コード・見出し行・上限・再引当の対象)
- [x] `docs/repository-structure.md`・`docs/glossary.md`(新しいモジュール・用語)

## 5. 検証

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`(全体)
- [ ] 受け入れ条件(requirements.md)を 1 項目ずつ照合
- [ ] 性能: 1,000 行の検証・保存が 30 秒以内(テストで確認)。引当の 15 分以内は在庫 API を含む実測が必要なため、未実測であることを PR に明記
