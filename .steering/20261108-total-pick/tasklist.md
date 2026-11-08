# タスクリスト: トータルピックと PDF 帳票(段階 5 のうち F-S6)

要求は [requirements.md](requirements.md)、設計は [design.md](design.md)。対象は `food_ship` のみ。単位ごとに品質ゲート(compile `--warnings-as-errors`・format・`credo --all`・test)を通してコミット・プッシュし、進捗に合わせてチェックを更新する。

実行環境: このセッションには `mix` / `elixir` が無い。`docker compose` が使えなければ、段階 3・4 と同様に `elixir:1.20.5-otp-29` と `postgres:15.2` を `--network host` で直接起動し、`/root/.ccr/ca-bundle.crt` を `SSL_CERT_FILE`・`HEX_CACERTS_PATH` に設定して `mix` を実行する。実 Chromium は `/opt/pw-browsers/chromium`（`PDF_CHROME_PATH`）を使う。

## 0. 実行環境

- [x] テスト実行環境を用意し、既存の `food_ship` の `mix test` が通ることを確認する（初回は `mix deps.get`）
- [x] `chromic_pdf` と `scrivener_ecto` の互換バージョンを確認する（design §8）
- [x] Chromium と日本語フォントの有無を確認する（sandbox ホストは `libnss3` 無しで実行不可・日本語フォントは WenQuanYi のみ → `apt-get install chromium fonts-noto-cjk` を入れたイメージ `food-ship-pdf` を作って使う）

## 1. 単位 A: 基盤・PDF 環境

- [x] `mix.exs` に `chromic_pdf`・`scrivener_ecto` を追加し、`Repo` に `use Scrivener, page_size: 20`
- [x] `Permission` に `manage_total_picks`（`staff`）を追加し、テストを更新
- [x] `FoodShip.Utils.Pdf`（アダプタへ委譲・`child_specs/0`）・`Pdf.Chromic`（`print_to_pdf`、`:busy` への変換、`%PDF` の検査）・`Pdf.Fake`
- [x] `config/config.exs`・`dev.exs`（`no_sandbox: true`）・`test.exs`（`Fake`・`start: false`）・`runtime.exs`（`PDF_POOL_SIZE`・`PDF_TIMEOUT_MS`・`PDF_CHROME_PATH`。本番節で `no_sandbox` を読まない）
- [x] `FoodShip.Application` に PDF の子プロセスを足す（`start: false` なら空）
- [x] `Dockerfile.dev` に `chromium` と `fonts-noto-cjk` を追加
- [x] `Pdf` のテスト（`Fake` の委譲・`child_specs/0`）と、実 Chromium のテスト（`@tag :pdf`。`PDF_TEST=1` のときだけ実行。`test_helper.exs` で除外）
- [x] ログのカテゴリを確認する（既存の `:other` を使う。カテゴリは追加しない）
- [x] 品質ゲート、コミット・プッシュ

- 実装メモ: ChromicPDF の既定出力は Base64 なので `Base.decode64` して `%PDF` を検査する。`deps/` の読み取りが許可されず API は既知の範囲で書いて実機テストで検証した。実機テストは `COMPOSE_FILE` に `image: food-ship-pdf:latest` の override を足して `PDF_TEST=1 mix test` で実行する

## 2. 単位 B: ピックの作成・集計（Context）

- [x] migration `create_total_picks`（シーケンス・テーブル・CHECK・索引・`shipping_slips.total_pick_id`・CHECK `total_pick_only_when_picked`）
- [x] `TotalPicks.TotalPick` スキーマ（`pick_no_label/1`・`status_label/1`）、`ShippingSlip` に `belongs_to :total_pick`、`preload_slip` に追加
- [x] `TotalPicks`: `list_candidates/1`・`create_total_picks/3`・`get_total_pick!/1`・`list_total_picks/1`・`summarize/1`
- [x] `TotalPicks`: `reissue_total_pick/2`・`cancel_total_pick/2`・`release/2`
- [x] フィクスチャ（`TotalPicksFixtures`。Context の公開 API 経由）
- [x] Context のテスト（design §9: 作成・除外条件・追加ピック・空選択・ロールバック・権限、再発行、取消、`release`、集計）
- [x] 並行性テスト（同じ伝票への同時作成で片方だけ成功。取消と伝票変更の同時実行でデッドロックしない）
- [x] 品質ゲート、コミット・プッシュ
- 実装メモ: `ShippingSlip` に `belongs_to :total_pick` を追加（`preload_slip` への `:total_pick` の追加は単位 C）。`list_total_picks/2` の `slip_count` は相関サブクエリで算出する。`list_makers/0`（絞り込みの選択肢）を追加した。フィクスチャの引当済み伝票は `InventoryStub.routes` で `allocated` にする（使うテストは `async: false` ＋共有モード）

## 3. 単位 C: 伝票の変更との連動

- [x] `ShippingSlips.update_shipping_slip/3` で、紐づき済みなら外して `TotalPicks.release/2`（同一トランザクション）
- [x] `ShippingSlips.cancel_shipping_slip/2`（`apply_outcome` に取消用の分岐）で、紐づき済みなら外して `release`
- [x] `list_shipping_slips/2` に `:unpicked` フィルタを追加
- [x] `ShippingSlips` のテスト（数量変更・出荷予定日変更・取消でピックが `outdated`／`cancelled`、梱包完了では変わらない、`stale` のときピックも変わらない）
- [x] 品質ゲート、コミット・プッシュ
- 実装メモ: 取消では `apply_outcome/3` の Multi に「伝票を `FOR UPDATE` で読み直して今の `total_pick_id` を控える → 更新 → `TotalPicks.release/2`」を足した。API 呼び出しの最中（確保のあと）にピックへ紐づけられても外れる（テストで再現）。`preload_slip` に `:total_pick` を追加した

## 4. 単位 D: 画面

- [x] `pagination` コンポーネントを `SlipComponents` に移植（在庫側からコピー）
- [x] `TotalPickLive.Index`（絞り込み・ページ送り）・`TotalPickLive.Show`（ヘッダ・明細・仕分け・伝票一覧・再発行・取消）とテスト
- [x] `ShippingSlipLive.Index`: ピック番号列・「未ピックのみ」・作業指示書リンク・「トータルピック作成」ダイアログ
- [x] 取消・数量変更の確認ダイアログに「トータルピック TP-xxxxxx から外れ、再発行が必要になります」を追記（`Index`・`Form`）
- [x] `router.ex`（一覧・詳細）、`Layouts` のナビに「トータルピック」
- [x] LiveView のテスト（表示と DB の両方、`viewer` に操作が出ない、イベント直接送信の拒否、ダイアログでの作成、対象が変わったときの警告）
- [x] `OperationLog`（作成・再発行・取消の成功のみ）
- [x] 品質ゲート、コミット・プッシュ

- 実装メモ（単位 D）: `pagination` は在庫側のコピーではなく、全クエリを引き継ぐ汎用版にして `SlipComponents` に置いた。`pick_status_badge`・`ShippingSlip.format_slip_no/1`・`SlipAllocatedLot.expiration_label/1` を追加し、期限日・伝票番号の整形を共通化した。ダイアログは daisyUI の `modal-open`（JS 不要）

## 5. 単位 E: 帳票

- [x] `ReportHTML`（`document/1`・`total_pick.html.heex`・`work_order.html.heex`。外部 URL なし、A4 縦、日本語フォント）
- [x] `ReportController`（`total_pick/2`・`total_pick_bundle/2`・`work_order/2`。状態ごとの応答、`:busy` は 503）
- [x] `router.ex`（`/reports/...`。staff 以上）、画面の PDF リンクをつなぐ
- [x] Controller のテスト（認可・状態ごとの応答・HTML に外部 URL が無い・日本語・合計行・仕分け表）
- [x] 品質ゲート、コミット・プッシュ
- 実装メモ（単位 E）: 画面のリンク（`~p`）がルートに依存するため、単位 D と E は同じコミットにした。HEEx の `<style>` 内は `{}` が展開されないので `<%= raw(@style) %>` で差し込む。`ReportController` の認可は plug に加えてアクション内でも `Permission.authorize` を呼ぶ。実機（実 Chromium）での見た目の確認は「6. 仕上げ」で行う

## 6. 仕上げ

- [ ] 実機確認: アプリを起動し、入荷 → 伝票登録 → 引当 → ピック作成 → PDF（ピック表・作業指示書・束ね）を取得して画像にレンダリングし、日本語・罫線・A4 縦・改ページを目視する。確認できなかった項目は理由を記録する
- [ ] 50 伝票の束ね PDF の生成時間を測る（目標 30 秒以内）。超える場合は残課題に記録する
- [ ] 両アプリで品質ゲート（`food_vault` が影響を受けていないこと）
- [ ] 永続ドキュメントの更新（承認を得て行う）: `functional-design.md`（`total_pick_id` の「段階 5 で追加」・ルーティング）・`architecture.md`（§3.2・§10・決定事項に追記）・`repository-structure.md`（計画 → 現状）・`development-guidelines.md`（段階 5 の進捗）・`glossary.md`（必要なら）
- [ ] 本ファイルの全項目を完了にし、コミット・プッシュ

## 残課題（今回の範囲外）

- 本番イメージ（`infra/`・Cloud Run）への Chromium・日本語フォントの追加と、非 root での実行（`no_sandbox` を使わない）
- 束ね PDF の非同期化（実測で 30 秒を超えた場合のみ）
- 出庫取消（F-S7）から `TotalPicks.release/2` を呼ぶこと
- CSV 取込・一括再引当（F-S5）、一括梱包完了（F-S8）、緊急操作（F-V8）、倉庫間移動（F-V9）、出庫取消（F-V7／F-S7）
