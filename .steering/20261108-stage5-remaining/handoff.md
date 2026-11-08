# 引き継ぎ: 段階 5 の残り(次のセッション用)

作成: 2026-11-08。ブランチ: `claude/bold-cerf-63i69o`(すべてプッシュ済み。未コミットの変更なし)。段階 5 は [development-guidelines §1.4](../../docs/development-guidelines.md) の「P1」全体。

## 1. 完了済み

- **F-S6 トータルピックと PDF 帳票**: 実装・テスト・永続ドキュメント反映まで完了。経緯と設計は [../20261108-total-pick/](../20261108-total-pick/)(requirements / design / tasklist)。`food_ship` 486 件・`food_vault` 447 件のテストが通過、compile 警告ゼロ・format 差分なし・credo 指摘なし。
- 本番イメージ(`food_ship/Dockerfile`)に `chromium`・`fonts-noto-cjk`・`HOME=/tmp`・`PDF_CHROME_PATH` を追加済み(`nobody` 実行のまま)。

## 2. 残り(未着手)と推奨順序

| 順 | 内容 | 要件 | 変更するアプリ | 参照 |
| :-- | :-- | :-- | :-- | :-- |
| 1 | CSV 一括取込・一括再引当・一括梱包完了 | F-S5・F-S8 | `food_ship` のみ | product-requirements F-S5・F-S8、functional-design §6.1(CSV 取込)・§6.2・§6.4 |
| 2 | 出庫取消(在庫 ④ API と発送側の `reversed` 遷移) | F-V7・F-S7 | 両方 | product-requirements F-V7・F-S7、functional-design §4.1・§4.2・§5.6・§6.6、architecture §7 |
| 3 | 緊急操作(発送システム起源オーダーの在庫側画面での確定・解除) | F-V8 | `food_vault` | product-requirements F-V8(L204〜) |
| 4 | 倉庫間移動 | F-V9 | `food_vault` | product-requirements F-V9、functional-design §5.7 |

- ユーザーは「残りを順に実装」を希望し、1 から始める想定で話が進んでいた(`requirements.md` はまだ作っていない)。
- 1 は DB 変更が小さい見込み(`shipping_slips.input_source = csv` は既存)。CSV の文字コード・列構成は product-requirements の未決事項 #2(UTF-8 か Shift_JIS か。設計は UTF-8 前提で進め、決めたら記録する)。
- **出庫取消(2)は、トータルピックと連動させる**: 梱包完了後の伝票が `reversed` になるとき、`FoodShip.TotalPicks.release(repo, slip_before)` を同一トランザクションで呼ぶ(関数は実装済み。設計: [../20261108-total-pick/design.md](../20261108-total-pick/design.md) §3・§4)。`shipping_slips` には `reversed_*` 列と CHECK が既にある。CHECK `total_pick_only_when_picked` は `allocated` / `packed` のみ許すので、`reversed` にする UPDATE で `total_pick_id` を NULL にすること。
- 在庫側の ④ は「ルートを作らない」状態で、`POST .../reverse` は共通形式の 404([../20261104-inventory-api/design.md](../20261104-inventory-api/design.md))。発送側 `Inventory.Client` は `release_remote_orders/3` が `reversed` を `{:error, {:remote_state, :reversed}}` として扱っている。

## 3. 進め方(CLAUDE.md・development-guidelines のルール)

1. 作業単位ごとに `.steering/[YYYYMMDD]-[タスク名]/` を作る(`requirements.md` → `design.md` → `tasklist.md`)。**1 ファイルずつ作成し、ユーザーの承認を得てから次へ**。承認後に実装する。
2. 実装前に CLAUDE.md・関連 `docs/`・既存の類似実装を確認する。対話・回答は日本語で、結論から簡潔に。
3. 単位ごとに品質ゲート(compile `--warnings-as-errors`・format・`credo --all`・test)を通し、コミット・プッシュ。コミットは「接頭辞: 要約」(日本語)＋ Co-Authored-By と Claude-Session の行。**PR は頼まれるまで作らない**。
4. 永続ドキュメント(`docs/`)の更新は、承認を得て行う(今回は `functional-design`・`architecture`・`repository-structure`・`development-guidelines` を更新した)。

## 4. 実行環境(このセッションで動いた手順)

- すべて**リポジトリのルート**(`/home/user/food_system`)で実行する(`COMPOSE_FILE` が相対パスを含むため、`food_ship/` に `cd` すると失敗する)。
  - 初回は `docker compose run --rm food_ship_web mix deps.get`(`food_vault_web` も同様)。DB は `docker compose up -d db`。
  - 品質ゲート: `R="docker compose run --rm food_ship_web mix"` として `$R compile --warnings-as-errors --force` / `$R format` / `$R credo --all` / `$R test`。
- セッションが新しいときは `bash scripts/cloud/setup.sh`(dockerd・ベースイメージ・DB の準備。[scripts/cloud/README.md](../../scripts/cloud/README.md))。
- **実 Chromium での PDF テスト(`@tag :pdf`)**: ホストの Chromium は `libnss3` 等が無くコンテナで動かない。`food-cloud-base` 由来のイメージに `apt-get update && apt-get install -y chromium fonts-noto-cjk` を入れて `docker commit` した `food-ship-pdf:latest` を作り、`image: food-ship-pdf:latest` だけの override ファイルを `COMPOSE_FILE` に足して `docker compose run --rm -v <出力先>:/out -e PDF_TEST=1 -e PDF_OUT_DIR=/out food_ship_web mix test <ファイル> --only pdf` を実行する。PDF は `pdftoppm -r 70 -png` で画像にして目視した。イメージはセッション間で残らない可能性が高いので、必要なら作り直す。
- 本番 Dockerfile のビルド確認: プロキシ用 CA を入れた builder イメージ(`hexpm/elixir` ＋ CA)を作り、`--build-arg BUILDER_IMAGE=... --build-arg HTTPS_PROXY="$HTTPS_PROXY"` を付けて `docker build --network host food_ship`。

## 5. 未解決・注意点

- **本番の PDF(Chromium のサンドボックス)**: コンテナでは非特権のユーザー名前空間が使えず、サンドボックスが起動しない(`No usable sandbox!`。`chromium-sandbox` を足しても `Failed to move to new namespace`)。このままでは Cloud Run で PDF が出ない。**ユーザーは「残課題にする」を選択済み**。案: `PDF_NO_SANDBOX=true` を Cloud Run だけに明示設定＋ChromicPDF `offline: true`＋`nobody` 実行で緩和し、architecture §10.2 を「Cloud Run は例外」に改める／本番では PDF を無効にする。Cloud Run(第 2 世代)での実挙動は未検証。メモリ 1Gi に対する `PDF_POOL_SIZE`(Terraform の `env`)も未決。記録先: [../20261108-total-pick/tasklist.md](../20261108-total-pick/tasklist.md) の残課題、architecture 決定事項 #4・#12。
- **画面のブラウザでの動作確認は未実施**(F-S6 の画面は LiveView のテストのみ)。現場での印刷確認も未実施。
- `deps/` 配下は、このセッションのツール権限で読み取りが拒否された(ChromicPDF の API は既知の範囲で書き、実機テストで確認した)。
- **`mix format` は HEEx の式の間の全角スペース(U+3000)を削除する**。区切りは ASCII(` / `)か CSS の余白にする。
- HEEx の `<style>` の中は `{}` が展開されない(`<%= raw(...) %>` を使う)。`ReportController` に `html/2` を定義すると `Phoenix.Controller.html/2` と衝突する。
- 並行性テストは `ConcurrencyCase`(`sandbox: false`・`async: false`・TRUNCATE で後始末)。テーブルを追加したら `test/support/concurrency_case.ex` の `@tables` に足す(F-S6 で `total_picks` を足した)。
- 引当済み伝票のテストデータは `FoodShip.TotalPicksFixtures.allocated_slip_fixture/2`(在庫 API のスタブ経由。使うテストは `async: false` ＋ `setup {Req.Test, :set_req_test_from_context}`)。
- ロック順序は「伝票 → ピック」で統一(新しい処理でも守る。[total_picks.ex](../../food_ship/lib/food_ship/total_picks.ex) の moduledoc)。
- 在庫 API を呼ぶ操作は、ローカル DB のトランザクションの外で行う(先に `pending` で保存 → API → 結果で更新。`ShippingSlips` の moduledoc)。一括処理(F-S5・F-S8)も 1 伝票ずつ `claim` → API → `apply_outcome` の既存の流れを再利用する。

## 6. 次の一手

1. このファイルと [../20261108-total-pick/tasklist.md](../20261108-total-pick/tasklist.md) を読み、ユーザーに着手する範囲(推奨: 順序 1)を確認する。
2. `.steering/{日付}-csv-import-bulk-ops/requirements.md` を作成して承認を得る(product-requirements F-S5・F-S8 の受け入れ条件と functional-design §6.1・§6.4 が根拠。性能目標: CSV 1,000 行の取込 30 秒以内・全行の引当完了 15 分以内)。
