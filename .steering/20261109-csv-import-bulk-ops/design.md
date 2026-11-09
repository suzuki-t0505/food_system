# 設計: CSV 一括取込・一括再引当・一括梱包完了(F-S5・F-S8)

- 要求: [requirements.md](requirements.md)(承認済み。見出し行必須・上限 2,000 行 / 1 MB・一括再引当は全日付)
- 対象: `food_ship` のみ。DB のマイグレーションなし(`shipping_slips.input_source = csv`・`client_slip_no` の部分ユニークインデックスは既存)。新しい依存ライブラリなし

## 方針

1. 在庫 API を呼ぶ処理は、既存の `allocate_shipping_slip/2`・`pack_shipping_slip/2` を **1 伝票ずつ**そのまま再利用する(確保 → API → 結果の反映、`stale` の扱いも既存のまま)。新しい引当ロジックは作らない
2. 「全件保存(トランザクション)→ 1 件ずつ順に API」の 2 段に分け、API の呼び出しをトランザクションに入れない
3. 順次処理のループは Context の 1 か所(`Bulk`)にまとめ、取込・一括再引当・一括梱包完了で共有する。画面は `Task` ＋ `handle_info` で進捗を受ける(既存の `busy` と同じ作り)
4. 進捗は画面の状態にだけ持つ。途中で止まっても、残りは `pending` / `allocated` のまま DB に残り、一括再引当・一括梱包完了のやり直しで復旧できる

## モジュール構成

| モジュール | 種別 | 役割 |
| :-- | :-- | :-- |
| `FoodShip.ShippingSlips.CsvParser`(新規) | 純粋関数 | CSV のバイト列 → 行(行番号つき)。BOM・UTF-8・引用符・改行・見出し行・上限を扱う |
| `FoodShip.ShippingSlips.CsvImport`(新規) | Context 補助 | 行の検証(形式 → マスタ → 重複)と保存。`ShippingSlips.import_csv/2` から呼ぶ |
| `FoodShip.ShippingSlips.Bulk`(新規) | Context 補助 | 伝票を順に処理するループ(`run/4`)と、一括再引当の対象の取得 |
| `FoodShip.ShippingSlips`(変更) | Context | 公開関数 `import_csv/2`・`list_reallocation_targets/0`・`list_slips_by_ids/1` を追加。`build_attrs` に `input_source` を渡せるようにする |
| `FoodShipWeb.ShippingSlipLive.Import`(新規) | LiveView | CSV アップロード、検証エラー一覧、取込結果と引当進捗 |
| `FoodShipWeb.ShippingSlipLive.Index`(変更) | LiveView | 「一括再引当」ボタン、行の選択と「選択した伝票を梱包完了にする」、進捗と結果の表示 |
| `FoodShipWeb.SlipComponents`(変更) | コンポーネント | 進捗バーと結果表の共通部品(`bulk_progress/1`・`bulk_results/1`) |
| `FoodShipWeb.SlipMessages`(変更) | 文言 | 取込の検証エラー・一括処理の結果の文言 |
| ルーター(変更) | | `staff` 以上のスコープに `live "/shipping_slips/import", ShippingSlipLive.Import, :new` |

## 1. CSV の解析(`CsvParser`)

`parse(binary) :: {:ok, [%{line: pos_integer, fields: [String.t()]}]} | {:error, message}`

- バイト列が 1 MB(1,048,576 バイト)を超える → `{:error, "ファイルが大きすぎます(上限 1 MB)。"}`。画面の `allow_upload` の `max_file_size` でも同じ値を弾く
- 先頭の UTF-8 BOM(`<<0xEF, 0xBB, 0xBF>>`)を除く。`String.valid?/1` が偽なら `{:error, "UTF-8 で保存し直してください。"}`(Shift_JIS のファイルはここで弾く)
- RFC 4180 の範囲を自前で解析する(ダブルクォートでの囲み・`""` のエスケープ・囲み内のカンマと改行・CRLF/LF)。`line` は**レコードの開始行**(物理行)。空行は無視する(末尾の改行を含む)
- 1 行目は見出し行。トリム・小文字化して `client_code, client_slip_no, scheduled_ship_date, item_code, order_count` と一致しなければ `{:error, "1 行目の見出しが正しくありません(client_code, … の順)。"}`。見出しを除いた行数が 0 → `{:error, "データ行がありません。"}`、2,000 を超える → `{:error, "行数が多すぎます(上限 2,000 行)。"}`
- 列数が 5 でない行は、ここでは弾かず `fields` のまま返し、検証(次節)で行番号つきのエラーにする(1 行ずつの報告を揃えるため)

## 2. 行の検証と保存(`CsvImport` / `ShippingSlips.import_csv/2`)

```elixir
import_csv(scope, binary) ::
  {:ok, [{行番号, %ShippingSlip{}}]}    # 保存した伝票。引当順(出荷予定日 → ファイル順)
  | {:error, {:invalid, [%{line: n, message: s}]}}
  | {:error, :forbidden | :warehouse_not_configured | :connection | :unauthorized | {:file, message}}
```

手順:

1. `authorize(scope, :manage_shipping_slips)` → `ensure_warehouse()`(未設定・通信失敗なら、ファイルを読む前に拒否)
2. `CsvParser.parse/1`。失敗は `{:error, {:file, message}}`(行番号なしのファイル単位のエラー)
3. **検証**(DB には書かない。エラーは全行ぶん集めて行番号順に返す):
   - 形式: 列数 5、各項目をトリム、必須の空欄(`client_slip_no` を含む)、`scheduled_ship_date` は `Date.from_iso8601`(`YYYY-MM-DD` のみ)、`order_count` は 1 以上の整数
   - マスタ: `client_code` / `item_code` を `IN` の 2 クエリでまとめて引く。未登録・アーカイブ済みは行のエラー。出荷期限ルールが無い組み合わせはエラーにしない(手入力と同じで、最低許容期限日は `nil`)
   - ファイル内の重複: `{client_code, client_slip_no, item_code}` が既出の行を、2 回目以降のエラー(「N 行目と重複しています」)
   - 既存との重複・数量の検証: 手入力と同じ `ShippingSlip.create_changeset/2`(`unsafe_validate_unique` ＋ `validate_master`)を行ごとに組んで `changeset.valid?` を見る。changeset の `errors` を「`項目名` + 文言」にして行番号に結び付ける
4. エラーが 1 件でもあれば `{:error, {:invalid, errors}}` を返して終わり(DB 変更なし)
5. 全行を 1 つの `Repo.transact` で、**ファイル順**に `Repo.insert`(`slip_no` の採番がファイル順になる)。`input_source = csv`・`created_by_user_id` は `scope.user.id`。挿入で `unique_constraint` が起きた(検証後に別の操作が同じ伝票番号を登録した)ら、その行を `{:invalid, [...]}` にして全体をロールバックする
6. 保存した伝票を `(scheduled_ship_date, 行番号)` の昇順に並べて返す(**保存は Task の前に完了している**)

`build_attrs/1` は `input_source` を `"manual"` 固定で入れているため、`build_attrs(attrs, source)` に直し、手入力は `"manual"`・CSV は `"csv"` を渡す(既存の呼び出しは `"manual"` のまま)。

## 3. 順次処理(`Bulk`)

```elixir
Bulk.run(scope, slips, fun, notify)
# fun:    (scope, slip) -> 既存の戻り値({:ok, slip} | {:ok, slip, info} | {:error, reason})
# notify: (index, total, slip, result) -> any   # 1 件ごとに呼ぶ(index は 1 始まり)
```

- `slips` を**与えられた順**に `fun` で 1 件ずつ呼び、結果を `notify` に渡す。1 件の例外(`rescue`・`catch`)は `{:error, :unexpected}` として扱い、残りは続ける
- 並び順を決めるのは呼び出し側(取込は引当順、一括再引当は `list_reallocation_targets/0`、一括梱包は `list_slips_by_ids/1`)
- `list_reallocation_targets/0`: `status in [:pending, :shortage]` かつ(`allocation_error` が `NULL` または**再試行で直るもの**)を、`scheduled_ship_date` 昇順 → `slip_no` 昇順で返す。再試行で直るものは `:connection`(一時)と `:idempotency_conflict`(再引当が旧オーダーの解除から行うため直る)。恒久エラー(`:unauthorized`・`:not_found`・`:validation_failed`)は対象外で、修正後に個別に再引当する。`ShippingSlip.retryable_error?/1` を追加して、この判定を 1 か所に置く
- `list_slips_by_ids/1`: ID のリストの伝票を、`scheduled_ship_date` 昇順 → `slip_no` 昇順で返す(発注元・商品・引当ロットを preload)
- 重複実行の防止: 同じ画面では `bulk` の状態で二重起動を弾く。別の利用者と重なった場合は、各伝票の確保(`claim`)・`stale` 判定で守られ、後から来た処理はその伝票が `{:error, :stale | :invalid_status}` の失敗になるだけでデータは壊れない

## 4. 画面

### 4.1 取込画面(`ShippingSlipLive.Import`、`/shipping_slips/import`)

- 作業画面のヘッダーに「CSV を取り込む」ボタン(`can_manage` のみ)を置いて遷移する。`staff` 未満はルーターで拒否される
- 状態(assign): `phase`(`:idle | :importing | :done`)・`errors`(`{:invalid, ...}` / ファイル単位のエラー)・`total`・`done`・`counts`(`allocated` / `shortage` / `pending` / `error` の件数)・stream `:results`
- フロー:
  1. `allow_upload(:csv, accept: ~w(.csv), max_entries: 1, max_file_size: 1_048_576, auto_upload: false)`。倉庫が未設定なら警告を出して送信を無効化(作業画面・フォームと同じ文言)
  2. 送信(`phx-submit="import"`): `consume_uploaded_entries` でバイト列を読み、`ShippingSlips.import_csv/2` を**画面のプロセスで**呼ぶ(検証・保存。性能目標 30 秒以内。1,000 行で同期でも許容範囲。`unsafe_validate_unique` を含め 1 行 1〜2 クエリ)
  3. `{:error, {:invalid, errors}}` → 行番号つきのエラー一覧(先頭 200 件を表示し、超過分は「ほか N 件」)。`{:error, {:file, msg}}` → ファイル単位のエラー。その他の `{:error, reason}` は `SlipMessages.error_message/1`
  4. `{:ok, slips}` → 全行を「引当待ち」として `:results` に挿入し、`phase = :importing`。`Task.start` で `Bulk.run(scope, slips, &allocate_shipping_slip/2, notify)` を実行。`notify` は `send(pid, {:bulk_progress, run_ref, kind, index, total, slip, result})`、終了時に `{:bulk_done, run_ref, kind}`
  5. `handle_info({:bulk_progress, ...})`: 該当行を `stream_insert` で更新し、`done`・`counts` を更新、成功した伝票は `OperationLog.info(socket, msg, :update, slip)`。`{:bulk_done, ...}`: `phase = :done`、取込の操作ログ(`:create`、件数と引当結果の内訳)を出す
- `Process.monitor/1` で Task を監視し、`{:DOWN, ...}` が `bulk_done` より先に来たら「処理が中断しました。作業画面の一括再引当で、残りを引き当ててください。」を表示して `phase = :done`
- 結果表の列: 行番号・伝票番号・発注元・商品・出荷予定日・件数・結果(`引当済み` / `在庫不足(不足 N 個)` / `引当待ち(原因)` / `エラー(文言)` / 処理待ち)
- 完了後に「作業画面へ」(取り込んだ最初の出荷予定日のタブ)を表示する。実行中は送信ボタンを無効化する

### 4.2 一括再引当(`ShippingSlipLive.Index`)

- ヘッダーに「一括再引当」ボタン(`can_manage` のみ。`data-confirm`)。倉庫が未設定、または `bulk` 実行中は無効化
- `handle_event("reallocate_all")`: 権限を検査 → `bulk` が実行中なら無視 → `list_reallocation_targets/0` が空なら info の flash「再引当の対象がありません。」→ `Task.start` で `Bulk.run(scope, targets, &allocate_shipping_slip/2, notify)`。対象の ID を全部 `busy` に入れる(対象行が無効化され「処理中…」になる)
- `handle_info({:bulk_progress, ...})`: その伝票を `busy` から外し、結果を stream `:bulk_results` に追加、`done`・`total` を更新、成功は操作ログ。`bulk_done` で `bulk = nil`、結果の要約を flash に出し、タブと伝票を読み直す
- 進捗パネル(`#bulk-panel`)に「処理中: 12 / 300 件」と、完了後の伝票ごとの成否一覧(伝票番号・発注元・商品・結果)を出す。パネルは「閉じる」で消せる

### 4.3 一括梱包完了(`ShippingSlipLive.Index`)

- `allocated` の行に、`can_pack` のときだけチェックボックス(`phx-click="toggle_select"`、`busy` の行と実行中は `disabled`)。ヘッダー行に「この日の `allocated` をすべて選択」を置く
- 選択状態は assign の `selected`(`MapSet`)。日付・フィルタを切り替える(`handle_params`)と、表示中の `allocated` でない ID を落とす
- 「選択した伝票を梱包完了にする(N 件)」ボタン(`data-confirm`: 件数と「在庫が減算され、元に戻せません」)。0 件・`bulk` 実行中は無効化
- `handle_event("pack_selected")`: 権限(`:pack_shipping_slips`)を検査 → `list_slips_by_ids(selected)` → `Task.start` で `Bulk.run(scope, slips, &pack_shipping_slip/2, notify)`。対象を `busy` に入れ、選択をクリアする。結果は 4.2 と同じパネルに「完了件数／全件」と伝票ごとの成否で出す。失敗した伝票は `allocated` のまま残り、`SlipMessages.error_message/1` の文言を成否に表示する(接続エラーは「在庫システムに接続できませんでした。時間をおいて…」)
- 個別の「梱包完了」・「再引当」・「取消」ボタンは、既存どおり行の `busy` で無効化される。一括の実行中は、対象外の行の個別操作は従来どおり行える(その伝票だけを確保して処理するため、一括と衝突しない)

### 4.4 `bulk` の状態(`Index`)

`bulk`: `nil` または `%{ref, kind: :reallocate | :pack, total, done, counts}`。`kind` ごとの文言は `SlipMessages` に置く。`Task` の監視(`Process.monitor`)で異常終了を検出し、`busy` を解放して「処理が中断しました。もう一度実行してください。」を表示する(`pending` / `allocated` のまま残るので、やり直せる)。

## 5. 文言(`SlipMessages`)

- 検証エラー: 「N 行目: client_code「X」は登録されていません。」の形式。項目ごとの文言は次のとおり
  - 空欄: 「N 行目: {列名}は必須です。」
  - 日付: 「N 行目: scheduled_ship_date は YYYY-MM-DD 形式で入力してください。」
  - 件数: 「N 行目: order_count は 1 以上の整数で入力してください。」
  - 重複: 「N 行目: client_slip_no「X」は M 行目と重複しています。」「N 行目: client_slip_no「X」はすでに登録されています。」
  - 列数: 「N 行目: 列数が正しくありません(5 列必要)。」
- 一括処理の結果の要約: 取込「N 件を取り込み、引当済み A 件・在庫不足 S 件・引当待ち P 件・エラー E 件でした。」、一括再引当・一括梱包完了も同じ形式

## 6. 権限・操作ログ・セキュリティ

- 取込・一括再引当は `:manage_shipping_slips`、一括梱包完了は `:pack_shipping_slips`(いずれも `staff` 以上)。ボタンの非表示に加え、イベント処理とルーターでも検査する(Context の関数も `authorize` で二重化)
- アップロードは `.csv` ・1 ファイル・1 MB まで。ファイルは一時領域で読み、保存しない。セル値は HEEx が自動エスケープして表示する。CSV の先頭が `=` `+` `-` `@` の値は、保存はそのままで、再出力しない(取込結果の CSV ダウンロードはスコープ外)
- 操作ログ: 伝票ごとの更新(`:update`)と、取込・一括再引当・一括梱包完了の単位の要約(取込は `:create`、他は `:update`)。`Task` の中ではログを出さず、`handle_info` で出す

## 7. 性能

- 検証・保存(1,000 行): マスタ 2 クエリ ＋ 1 行ごとの `unsafe_validate_unique`(1 クエリ)＋ 挿入 1 回 ≒ 3,000 クエリ弱。テストで 1,000 行が 30 秒以内であることを確認する
- 引当(1,000 件): 1 件あたり「デフォルト倉庫の取得 ＋ 照会(再引当のみ)＋ 引当 POST」。直列で、在庫 API の応答時間が支配的。15 分(900 秒)÷ 1,000 件 = 0.9 秒/件の予算。デフォルト倉庫の取得を毎回行う設計(キャッシュなし、default-warehouse の決定)は変えない。実測で足りなければ後続で見直す
- 画面の更新は stream で行い、進捗のたびに 1 行ぶんだけを送る

## 8. テスト方針

- `CsvParser`(単体): BOM・CRLF・引用符内のカンマ/改行・空行・見出し不一致・データ行なし・行数/サイズ上限・不正な UTF-8
- `ShippingSlips.import_csv/2`(Context): 正常系(全行が `csv` / `pending`、`slip_no` がファイル順、戻りが出荷予定日 → ファイル順)、検証エラーのどれか 1 行で 1 件も保存されない、`client_slip_no` の空欄・ファイル内重複・既存との重複・未登録/アーカイブ済みコード・日付/件数の不正の行番号つきエラー、倉庫未設定・`viewer` の拒否、1,000 行の性能
- `Bulk`: 渡した順に処理する、例外でも残りを続ける、`list_reallocation_targets/0` の順序と恒久エラーの除外、`list_slips_by_ids/1` の順序
- LiveView(`async: false`・`Req.Test` の共有モード): 取込(アップロード → 結果表 → 在庫不足行が `shortage`)、検証エラーの表示と未保存、実行中の送信無効化、`Task` 中断の表示、一括再引当(順序・恒久エラー除外・結果一覧・実行中の無効化・`viewer` に非表示)、一括梱包完了(進捗・失敗した伝票が `allocated` のまま・実行中の無効化・二重実行不可・`viewer` に非表示)
- `mix format --check-formatted`・`mix compile --warnings-as-errors`・`mix test`(この環境には Elixir が無いため、実行はユーザー側の環境または CI で行う。未実行の項目は tasklist に明記する)

## 9. 永続ドキュメントの更新

- `product-requirements.md`: 未決事項 #2 に「UTF-8・見出し行あり・上限 2,000 行 / 1 MB で進める」を記録し、F-S5 の受け入れ条件に反映
- `functional-design.md` §6.1・§6.2: 文字コード・見出し行・上限・恒久エラーの範囲(`idempotency_conflict` は対象)を追記
- `repository-structure.md`・`glossary.md`: 新しいモジュール・用語(一括再引当の対象)があれば追記

## 判断した点(承認時に変更可)

1. 日付は `YYYY-MM-DD` のみ受け付ける(`2026/11/20` は検証エラー)
2. 一括再引当の対象に `idempotency_conflict` の `pending` を含める(再引当が解除から行うため)。含めない場合は `retryable_error?/1` を `:connection` のみにする
3. 検証・保存は画面のプロセスで同期実行し、引当だけを `Task` にする(functional-design §6.1 の「保存は Task の前に完了」に合わせる)

## 実装時の補足(設計からの差分)

- `CsvImport.prepare/1` は `{検証を通った行, エラー}` を常に返し、`import_csv/2` が既存との重複・数量の検証(changeset)とあわせてエラーを全行ぶんまとめる(設計では段階を分けて返す想定だったが、利用者が一度に全てのエラーを直せるようにした)
- 一括処理の対象行は、進捗のたびではなく**全件の処理後にまとめて**表示を更新する(進捗のたびに表全体を再送しないため)。実行中は対象全件を `busy` にして無効化し、行ごとの成否は進捗パネルの結果表に出す
- 件数は 1〜1,000,000、出庫総数量・箱数は 4 バイト整数の範囲を検証する(桁あふれを保存前に弾く)
