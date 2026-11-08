# 要求内容: トータルピックと PDF 帳票(段階 5 のうち F-S6)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 5)、[product-requirements.md F-S6](../../docs/product-requirements.md)、[functional-design.md §3.2(`total_picks`)・§4.3・§6.8・§6.9・§8.2](../../docs/functional-design.md)、[architecture.md §10](../../docs/architecture.md)
- 対象アプリ: `food_ship`(発送)。`food_vault` は変更しない
- 位置づけ: 段階 4(発送側 P0)の次。段階 5(P1)は範囲が広いため、今回は **F-S6 のみ**を扱う(ユーザーと合意済み)

## 背景

作業画面で伝票を引当・梱包できるが、現場に渡す帳票が無い。`shipping_slips` に `total_pick_id` 列、`total_picks` テーブル、`TotalPicks` Context、`ReportController`、PDF 生成(`Utils.Pdf`)はいずれも未実装。発送側の `Dockerfile.dev` には Chromium・日本語フォントが無く、`mix.exs` に ChromicPDF も無い(architecture §10 は「環境構築は別セッション」としていたが、PDF を出すために本作業で最小限を整える)。

## 要求(スコープ)

### トータルピックの作成(§6.8)

- 作業画面の出荷予定日タブに「トータルピック作成」を追加する。未ピックの引当済み伝票(`status = allocated` かつ `total_pick_id IS NULL`)を「発注元 × メーカー」のグループに分けて表示し(伝票数・商品数・合計バラ数のプレビュー付き)、選んだグループごとに 1 つの `total_picks` を作る
- ピックの挿入と伝票の更新は 1 トランザクション。対象伝票を `FOR UPDATE` でロックし、同時に作成しても同じ伝票が二重にピックされない(後続は対象 0 件で失敗)
- `pick_no` は DB シーケンス採番(`TP-000045` 形式)。`inventory_maker_id`・`maker_name` は作成時点の値を保存する
- 対象外: `pending` / `shortage` / `packed` / `cancelled` / `reversed`、すでにピック済みの伝票
- 追加伝票は同じグループの別ピック(追加ピック)になり、既存のピックは変えない

### 一覧・詳細・状態(§4.3・§6.8)

- 一覧(`/total_picks`): 出荷予定日・発注元・メーカー・状態(発行済／要再発行／取消)で絞り込み。ページ送りあり。参照は全ロール
- 詳細(`/total_picks/:id`): ピック明細(商品 × 期限日の合算)・仕分け内訳(明細行ごとの「伝票番号 × 数量」)・紐づく伝票一覧。集計は都度、伝票の引当ロット明細から算出する(合計値を別テーブルに持たない)。梱包済みの伝票も集計に含む
- **再発行**(`outdated` かつ紐づく伝票 1 件以上): `revision` を加算し `issued` に戻す。`issued_at`・`issued_by_user_id` を更新する
- **取消**(紐づく伝票がすべて `allocated` のとき): `cancelled` にして伝票を未ピックに戻す
- 紐づく伝票が 0 件になったピックは自動で `cancelled`

### 伝票の変更に伴うピックの更新(§6.8)

- 紐づき済みの伝票を **数量変更・出荷予定日変更・取消**したとき、その伝票を同一トランザクション内でピックから外し(`total_pick_id` を NULL)、ピックを `outdated` にする(0 件なら `cancelled`)。数量・日付の変更で外れた伝票は、再引当後に再びピック作成の対象になる
- 再引当(数量変更を伴わないもの)と梱包完了はピックの状態に影響しない(`packed` になってもピックから外さない)
- 確認ダイアログに「トータルピック TP-xxxxxx から外れ、再発行が必要になります」を表示する
- 出庫取消(F-S7)は段階 5 の別作業のため今回は扱わない(同じ「ピックから外す」処理を呼べる形にしておく)

### 作業画面の変更

- 伝票行に **ピック番号**(詳細へのリンク)を表示し、状態フィルタに **「未ピックのみ」**を追加する
- 伝票行に **作業指示書 PDF** へのリンクを追加する(`allocated` / `packed` のみ)

### PDF 帳票(§6.9・architecture §10)

- `FoodShipWeb.ReportController`: `total_pick/2`(ピック表のみ)・`work_order/2`(作業指示書 1 枚)・`total_pick_bundle/2`(ピック表 → 作業指示書を `slip_no` 昇順で 1 つの PDF)。認可は HTTP plug で `staff` 以上。`outdated` / `cancelled` のピックは PDF を出力できない(再発行を促す)
- **トータルピック表**: ヘッダ(ピック番号・版・出荷予定日・発注元・メーカー・発行日時・発行者)、明細(商品コード・商品名・期限日・合計バラ数・合計件数・合計箱数・チェック欄)、最終行に合計、後半に仕分け表
- **作業指示書**: 伝票番号・発注元・発注元伝票番号・出荷予定日・メーカー・商品コード・商品名・件数・箱数・出庫数量(バラ)・引当ロットの期限日 × 個数・最低許容期限日(ルールがある場合)・所属ピック番号・実績記入欄(実際の箱数・担当者・検品)
- 帳票は都度生成して保存しない。日時は JST。A4 縦・日本語フォント(Noto Sans JP)。バーコード／QR は印字しない
- 生成は `FoodShip.Utils.Pdf`(外部境界。ChromicPDF)に閉じ込める。テンプレートに外部リソース(画像・フォント・スクリプト・CSS の外部 URL)を書かない。差し込む値は HEEx のエスケープのみ
- 環境構築: `mix.exs` に ChromicPDF、アプリ起動時の supervisor 登録(設定でプール数・タイムアウト。テスト環境では起動しない)、`Dockerfile.dev` に Chromium と `fonts-noto-cjk`、`no_sandbox` は開発・テスト（root）に限る

### 認可・周辺

- `Permission` に `manage_total_picks`(`staff` 以上: 作成・再発行・取消・PDF 出力)を追加。認可は plug・`on_mount`・イベントの 3 層。`viewer` は一覧・詳細の参照のみ
- ナビゲーションに「トータルピック」を追加
- Logger／`OperationLog`(作成・再発行・取消の成功のみ。`Task` の中では出さない)
- 永続ドキュメントへの反映(`functional-design.md`・`architecture.md`・`repository-structure.md`・`development-guidelines.md`・`glossary.md` のうち影響するもの)

## 受け入れ条件

- [ ] 出荷予定日タブから、未ピックの `allocated` 伝票が「発注元 × メーカー」ごとにプレビュー付きで表示され、選んだグループでピックを作成できる。作成後に詳細へ遷移する。`pending` / `shortage` / `packed` / `cancelled` とピック済みの伝票は対象にならない
- [ ] 同じ伝票に対するピック作成を同時に実行しても、片方だけが成功し二重にピックされない(並行性テスト)
- [ ] 追加伝票は別ピックになり、既存のピックは変わらない
- [ ] 紐づく伝票の数量変更・出荷予定日変更・取消で、その伝票が外れ、ピックが `outdated`(0 件なら `cancelled`)になる。外れた伝票は未ピックに戻る。梱包完了ではピックの状態も紐づきも変わらない
- [ ] `outdated` のピックを再発行すると `revision` が加算され `issued` に戻り、PDF を出力できる。再発行前は PDF を出力できない。取消は全伝票が `allocated` のときだけできる
- [ ] ピック詳細に、商品 × 期限日の合算(期限なしは「期限なし」)と仕分け内訳が表示され、梱包済みの伝票も含まれる
- [ ] ピック表 PDF・作業指示書 PDF・束ね PDF をダウンロードできる。日本語が正しく表示され A4 縦に収まる(実機で PDF をレンダリングして確認する)。`staff` 未満は拒否される
- [ ] 作業画面にピック番号・「未ピックのみ」フィルタ・作業指示書リンクが出る。`viewer` には操作が出ず、イベントを直接送っても拒否される
- [ ] テスト: Context(成功系と失敗系・失敗時の DB 状態・集計)、LiveView(表示と DB の書き込み)、Controller(認可・状態ごとの応答。`Utils.Pdf` は差し替え)、`Utils.Pdf`(実 Chromium で `%PDF` を返す。Chromium が無い環境ではスキップ)。`make check` 相当(compile 警告ゼロ・format 差分なし・credo・test)が `food_ship` で通り、`food_vault` に影響しない

## スコープ外(段階 5 の他の作業)

- F-S5 CSV 取込・一括再引当、F-S8 一括梱包完了
- F-V7／F-S7 出庫取消、F-V8 緊急操作、F-V9 倉庫間移動(在庫側 `food_vault` の変更を含む)
- バーコード／QR、帳票の保存、帳票の編集機能
- 本番の PDF 実行環境(root 以外のユーザー・Cloud Run 上の Chromium)の構築。本作業では `Dockerfile.dev` と設定値までとし、本番イメージへの反映は別途 tasklist に残課題として記録する

## 決定事項

- ステアリングは requirements → design → tasklist の順に 1 ファイルずつ承認を得る(CLAUDE.md)
- 作業単位(基盤・PDF 環境 → ピック作成・集計 → 画面 → 伝票変更との連動 → 帳票)ごとに品質ゲートを通してコミットする
- ピック明細は持たず都度集計する(functional-design §3.2)。ユニーク制約は設けない(追加ピックを許すため)

## 未確定(design.md で決める)

- ChromicPDF の起動方法(supervisor への登録条件、テスト環境での無効化)と、Chromium の実行パス・`no_sandbox` の設定キー
- `shipping_slips.total_pick_id` の FK の `on_delete` と、`total_picks.status` / `revision` の CHECK 制約
- 伝票の変更時にピックから外す処理の呼び出し位置(`ShippingSlips` の既存関数への組み込み方。`TotalPicks` との循環参照を避ける)
- 集計クエリの構成(`defp *_query/2` への分割)と、仕分け表のデータ構造
- 束ね PDF が大きい場合の非同期化の要否(目標: 50 伝票で 30 秒以内)
- 作業画面の「トータルピック作成」ダイアログの実装(モーダルか別画面か)
