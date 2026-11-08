# 設計: トータルピックと PDF 帳票(段階 5 のうち F-S6)

要求は [requirements.md](requirements.md)。対象は `food_ship` のみ(`food_vault` は変更しない)。基本設計は [functional-design §3.2・§4.3・§6.8・§6.9](../../docs/functional-design.md)、[architecture §10](../../docs/architecture.md) に従い、ここでは「既存コードにどう載せるか」と、要求の「未確定」を決める。

## 1. 決定事項(未確定の解消)

| 論点 | 決定 | 理由 |
| :-- | :-- | :-- |
| ピックから外す処理の呼び出し位置 | `ShippingSlips.update_shipping_slip/3` と `cancel_shipping_slip/2` の**既存トランザクションの中**で `TotalPicks.release/2` を呼ぶ。依存は `ShippingSlips → TotalPicks` の一方向(`TotalPicks` は `ShippingSlips` を呼ばない) | 伝票の変更とピックの更新を同一コミットにし、中途半端な状態(伝票は外れたがピックは `issued` のまま)を作らない。出庫取消(F-S7)も同じ関数を呼べる |
| ロック順序 | **伝票 → ピック**の順に統一する。作成は伝票を `FOR UPDATE` → ピックを挿入。再発行・取消は紐づく伝票を `FOR UPDATE` で先に読んでからピックを `FOR UPDATE`。`release/2` は呼び出し側がすでに伝票をロック済みで、ピックを後からロックする | 逆順があると、取消と伝票変更の同時実行でデッドロックしうるため |
| 明細の件数・箱数の持ち方 | ピック表の明細は「商品 × 期限日」ごとに **バラ数**を出す。**件数・箱数は商品単位**(その商品の全伝票の `order_count` / `box_count` の合計)で、商品の先頭行にだけ出す | ロットは個数単位なので、期限日ごとに分けると件数が整数にならない場合がある(商品数量 10 個/件で 25 + 25 に分かれるなど)。バラ数の合計 = 件数合計 × 商品数量は保たれる |
| 一覧のページング | 在庫側と同じ `scrivener_ecto`(`Repo` に `use Scrivener, page_size: 20`)を発送側にも追加し、`pagination` コンポーネントを `FoodShipWeb.SlipComponents` に移植する | 既存の方式に合わせる(architecture 決定 #9) |
| `total_pick_id` の CHECK | `total_pick_id IS NULL OR status IN ('allocated', 'packed')`。FK は `on_delete: :nothing` | 作成時に紐づくのは `allocated` のみで `packed` でも外さない。取消・変更で外れる際は、同一 `UPDATE` で `status` と `total_pick_id` を一緒に更新するので制約に反しない |
| PDF の差し替え | `FoodShip.Utils.Pdf` が `config :food_ship, FoodShip.Utils.Pdf, adapter: ...` のモジュールへ委譲する。本番・dev は `Pdf.Chromic`(ChromicPDF)、test は `Pdf.Fake`(`"%PDF-FAKE\n" <> html` を返す) | テストで HTML の内容(日本語・数量・外部 URL が無いこと)を検査できる。実 Chromium のテストは `@tag :pdf` で分け、`PDF_TEST=1` のときだけ実行 |
| ChromicPDF の起動 | `config :food_ship, FoodShip.Utils.Pdf, start: true/false`。test は `false`(実機テストだけ `start_supervised`)。`session_pool: [size: PDF_POOL_SIZE(既定 2), timeout: PDF_TIMEOUT_MS(既定 30000)]`、`chrome_executable: PDF_CHROME_PATH`(任意。未設定なら PATH 上の `chromium`)、`no_sandbox` は **dev のみ true**(`config/dev.exs`)。`runtime.exs` の本番節では読まない | architecture §10.2。root 実行の開発環境に限りサンドボックスを無効にする |
| 非同期化 | 今回は**しない**。束ね PDF は 1 つの HTML(`break-after: page` で改ページ)を 1 回の印刷で出力する。50 伝票で 30 秒以内かを実機で測り、超えるなら tasklist の残課題にする | 先に単純な方式で測る。プールが埋まっているときは `{:error, :busy}` → 503「混み合っています」 |
| 作成ダイアログ | 作業画面内の daisyUI モーダル(`<dialog>`)。`open_pick_dialog` でプレビューを読み、`create_picks` で作成。DB のみの処理なので `Task` にしない | 在庫 API を呼ばないため、同期で足りる |
| 複数グループの作成 | 選んだグループをまとめて 1 トランザクションで作る。どれかのグループの対象が 0 件(プレビュー後に他の操作で変わった)なら**全体をロールバック**して `{:error, :no_target}`。画面はプレビューを読み直して「対象が変わりました」を表示 | 部分的に成功すると画面の選択と結果がずれる |

## 2. DB

### 2.1 マイグレーション `create_total_picks`(`20261108100000`)

- `CREATE SEQUENCE total_picks_pick_no_seq`(`execute(up, down)` 形式。`shipping_slips` と同じ)
- `total_picks`: `id`(ULID)・`pick_no`(`DEFAULT nextval`、UNIQUE)・`scheduled_ship_date`・`client_id`(FK)・`inventory_maker_id`・`maker_name`・`status`(string, 既定 `issued`)・`revision`(既定 1)・`issued_at`(`utc_datetime`)・`issued_by_user_id`(FK)・`timestamps`
- 制約: `revision >= 1`(`revision_positive`)、`status IN ('issued','outdated','cancelled')`(`status_valid`)
- 索引: `(scheduled_ship_date, status)`・`(client_id)`・`(issued_by_user_id)`・`(inventory_maker_id)`
- `alter table(:shipping_slips)`: `add :total_pick_id, references(:total_picks, type: :binary_id, on_delete: :nothing)` ＋ 索引 `(total_pick_id)` ＋ CHECK `total_pick_only_when_picked`(§1)。**後方互換**(NULL 可の列追加。旧コードは列を知らないだけで動く。development-guidelines §3.1)

### 2.2 スキーマ

- `FoodShip.TotalPicks.TotalPick`: `pick_no` は `read_after_writes: true`(`slip_no` と同じ)。`pick_no_label/1`(`TP-000045`)・`status_label/1`・`statuses/0`。`belongs_to :client`・`:issued_by_user`・`has_many :shipping_slips`
- `ShippingSlip`: `belongs_to :total_pick`、`field` ではなく関連で持つ。`update_changeset/2` には含めず、Context が `put_change(:total_pick_id, nil)` する。`preload_slip/1` に `:total_pick` を追加

## 3. Context: `FoodShip.TotalPicks`

書き込み関数は先頭引数に `Scope`、`Permission.authorize(user, :manage_total_picks)` を検査する(`ShippingSlips` と同じ)。

| 関数 | 内容 | 戻り値 |
| :-- | :-- | :-- |
| `list_candidates(date)` | 未ピックの `allocated` 伝票(その日付)を `{client_id, inventory_maker_id}` でグループ化し、`%{client, maker_name, inventory_maker_id, slip_count, item_count, total_pieces}` を返す。`item_count` は商品の種類数 | `[group]` |
| `create_total_picks(scope, date, groups)` | `groups` は `[{client_id, inventory_maker_id}]`。1 トランザクションで、グループごとに対象伝票を `FOR UPDATE`(`ORDER BY id`)→ 0 件なら rollback → ピックを挿入 → 伝票の `total_pick_id` を `update_all` | `{:ok, [pick]}` / `{:error, :forbidden \| :no_target \| :empty_selection}` |
| `get_total_pick!(id)` | 発注元・発行者・伝票(`slip_no` 昇順。商品・引当ロット付き)を preload | pick |
| `list_total_picks(params)` | `scheduled_ship_date`・`client_id`・`inventory_maker_id`・`status` で絞り込み。`scheduled_ship_date` 降順・`pick_no` 降順。`Repo.paginate` | `%Scrivener.Page{}` |
| `summarize(pick)` | 明細と仕分け内訳(§3.1) | `%{lines: [...], totals: %{...}}` |
| `reissue_total_pick(scope, pick)` | 紐づく伝票を `FOR UPDATE` → ピックを `FOR UPDATE`。`outdated` かつ伝票 1 件以上のみ。`revision + 1`・`issued`・`issued_at`・`issued_by_user_id` | `{:ok, pick}` / `{:error, :forbidden \| :invalid_status \| :stale}` |
| `cancel_total_pick(scope, pick)` | 同順序でロック。`issued` / `outdated` で、紐づく伝票がすべて `allocated` のときのみ。伝票の `total_pick_id` を NULL → ピックを `cancelled` | `{:ok, pick}` / `{:error, :forbidden \| :invalid_status \| :has_packed_slips}` |
| `release(repo, slip)` | **`ShippingSlips` から呼ばれる内部 API**。`slip.total_pick_id` が NULL なら `:ok`。あれば(伝票側の `total_pick_id` は呼び出し側が同じ `UPDATE` で NULL にしてある前提で)ピックを `FOR UPDATE` して、残りの伝票が 0 件なら `cancelled`、そうでなく `issued` なら `outdated`。`outdated` / `cancelled` はそのまま | `:ok` |

`release/2` の注意: 引数の `slip` は**更新前**の構造体(`total_pick_id` を持つ)。呼び出し側は、伝票の更新後に `TotalPicks.release(Repo, slip_before)` を呼ぶ。

### 3.1 集計(`summarize/1`)

- 元データ: `slip_allocated_lots` ⨝ `shipping_slips`(`total_pick_id = ^id`)⨝ `shipping_items`。**梱包済みも含める**(`status` で絞らない)。`cancelled` / `pending` の伝票はそもそも紐づかない
- 1 本のクエリで `(item_id, expiration_date, slip_id)` ごとの `allocated_pieces` を取り、Elixir 側で集約する(`defp *_query/2` に分割。テンプレートに計算式を書かない)
  - `lines`: 商品コード順 → 期限日昇順に並べた `%{item, expiration_date, pieces, slips: [%{slip, pieces}]}`(`slips` が仕分け内訳。`slip_no` 昇順)
  - `item_totals`: 商品ごとの `%{item, order_count, box_count, pieces}`(`order_count` / `box_count` は伝票の合計。重複を数えないよう伝票単位で集計する)
  - `totals`: 全体の `pieces`・`order_count`・`box_count`
- 期限なし(`9999-12-31`)は、表示用に `no_expiration?` で「期限なし」。ソートは期限日昇順(期限なしが最後)

## 4. `ShippingSlips` の変更

- `update_shipping_slip/3`: `update_unpacked/2` の中で、`slip.total_pick_id` があれば `put_change(:total_pick_id, nil)` ＋ 更新後に `TotalPicks.release(Repo, slip)`。既存の `Repo.transact` の中なので同一トランザクション
- `cancel_shipping_slip/2`: 在庫側の解除に成功したあとの `apply_outcome/3` で、`attrs` に `total_pick_id: nil` を含め、Multi に `Multi.run("release_pick", ...)` を足す(`apply_outcome/3` に `opts` を追加するのではなく、取消用の attrs に `total_pick_id` を入れ、`replace_lots` と同様に末尾で `release` を呼ぶ小さな分岐を設ける)。`stale` のときは Multi 全体がロールバックされ、ピックも変わらない
- `list_shipping_slips/2`: `filter` に `:unpicked`(`status = :allocated and is_nil(total_pick_id)`)を追加。`preload_slip` に `:total_pick`
- 出庫取消(F-S7)は今回扱わないが、同じ `TotalPicks.release/2` を呼べばよい(ドキュメントに記す)

## 5. 認可・ルーティング

- `Permission`: `manage_total_picks: :staff`(作成・再発行・取消・PDF 出力)
- ルート:
  - 全ロール(`live_session :require_authenticated_user`): `live "/total_picks", TotalPickLive.Index, :index`、`live "/total_picks/:id", TotalPickLive.Show, :show`
  - staff 以上(`pipe_through [:browser, :require_authenticated_staff_user]` の通常コントローラ。`live_session` の外): `get "/reports/total_picks/:id", ReportController, :total_pick`、`get "/reports/total_picks/:id/bundle", ReportController, :total_pick_bundle`、`get "/reports/work_orders/:id", ReportController, :work_order`
- 3 層: ① HTTP plug(上記)、② `on_mount`(一覧・詳細は全ロールの `ensure_authenticated`)、③ イベント内の `Permission.can?`(作成・再発行・取消)＋ Context の `authorize`

## 6. 画面

### 6.1 作業画面(`ShippingSlipLive.Index`)の変更

- ヘッダの操作に「トータルピック作成」(`@can_pick`)。押すと `open_pick_dialog` でプレビュー(`list_candidates(@date)`)を読み、`<dialog class="modal">` に「発注元 / メーカー / 伝票数 / 商品数 / 合計バラ数」のチェックボックス一覧を表示。対象が無ければ「未ピックの引当済み伝票はありません。」
- `create_picks`(`groups` の値は `"client_id:maker_id"`)→ `TotalPicks.create_total_picks/3`。成功したら 1 件なら `push_navigate` で詳細へ、複数なら `/total_picks?date=` へ。`{:error, :no_target}` はプレビューを読み直して警告
- 状態フィルタに「未ピックのみ」(`unpicked`)を追加
- 表の列に「ピック」(ピック番号。`TP-000045` から詳細へのリンク、`outdated` は「要再発行」バッジ)。操作列に `allocated` / `packed` の「作業指示書」リンク(`@can_pick`、`target="_blank"`)
- 取消の確認ダイアログ: `slip.total_pick` があれば「トータルピック TP-xxxxxx から外れ、再発行が必要になります。」を追記。数量変更フォーム(`Form`)の `confirm_message/2` も同様

### 6.2 `TotalPickLive.Index`(`/total_picks`)

- 絞り込みフォーム(出荷予定日・発注元・状態。メーカーは選択肢が在庫側由来の ID なので、`maker_name` のテキスト一致ではなく**ピック作成済みの `inventory_maker_id` のみ**から選ぶ)・一覧(ピック番号・版・出荷予定日・発注元・メーカー・伝票数・状態・発行日時)・ページ送り。URL の `params` で状態を持つ(`handle_params`)

### 6.3 `TotalPickLive.Show`(`/total_picks/:id`)

- ヘッダ(ピック番号・版・状態・出荷予定日・発注元・メーカー・発行日時・発行者)
- 操作(`@can_pick`): PDF(ピック表のみ／ピック表＋作業指示書。`issued` のみ表示、`outdated` には「再発行してください」)、再発行(`outdated` のみ)、取消(確認ダイアログ付き)
- ピック明細(商品 × 期限日の合算＋チェック欄なし)、仕分け内訳(行ごとの「S-000123 × 20」)、紐づく伝票一覧
- 再発行・取消は DB のみなので同期。`OperationLog` は成功後に出す

## 7. 帳票(`ReportController` / `ReportHTML` / `Utils.Pdf`)

- `FoodShipWeb.ReportController`: `total_pick/2`・`total_pick_bundle/2`・`work_order/2`
  - 認可は `require_authenticated_staff_user`(plug)。`Permission.authorize` も呼ぶ
  - `issued` 以外のピックは `redirect` ＋ `put_flash(:error, ...)`(`outdated`: 「要再発行です。再発行してから出力してください。」、`cancelled`: 「取消済みのトータルピックは出力できません。」)で詳細へ戻す。作業指示書は `allocated` / `packed` 以外なら作業画面へ
  - 応答: `application/pdf`、`content-disposition: inline; filename="TP-000045.pdf"` / `"S-000123.pdf"`、`cache-control: no-store`
  - `{:error, :busy}` は 503「PDF の生成が混み合っています。しばらくしてからやり直してください。」、その他の失敗は 500（`Logger` に原因。内部情報は画面に出さない）
- `FoodShipWeb.ReportHTML`(`embed_templates "report_html/*"`): `total_pick.html.heex`・`work_order.html.heex` と、共通の `document/1`(`<!doctype html>`、`<style>` のみ。A4 縦: `@page { size: A4 portrait; margin: 12mm }`、`font-family: "Noto Sans JP", "Noto Sans CJK JP", sans-serif`、罫線表、`break-after: page`)。外部 URL を書かない
  - トータルピック表: ヘッダ、明細(商品コード・商品名・期限日・バラ数・件数・箱数・チェック欄。件数・箱数は商品の先頭行のみ、`rowspan` は使わず空セルで保つ)、合計行、改ページしてから仕分け表(行ごとの伝票番号 × 数量)。日時は `ConvertDatetime.format_jst/1`
  - 作業指示書: 伝票 1 枚。引当ロットは `SlipComponents.lot_label/1` を再利用。最低許容期限日は無ければ「なし」。実績記入欄（実際の箱数・担当者・検品）は罫線の空欄
- `FoodShip.Utils.Pdf.render(html) :: {:ok, binary} | {:error, :busy | term}`: アダプタへ委譲。`Pdf.Chromic` は `ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: %{paperWidth: 8.27, paperHeight: 11.69, preferCSSPageSize: true, printBackground: true}, ...)`。プール待ち超過（`checkout_timeout`）は `:busy` に変換。結果の先頭が `%PDF` であることを検査し、違えば `{:error, :invalid_pdf}`
- ログ: `FoodShip.Utils.Logger` に既存のカテゴリがあれば使い、なければ追加せず `:error` レベルの既存カテゴリに出す（実装時に確認。`raise_on_unknown_category` に注意）

## 8. 依存・環境

- `mix.exs`: `{:chromic_pdf, "~> 1.17"}`（実装時にロックされる最新の互換版を確認）・`{:scrivener_ecto, "~> 3.1"}`
- `Dockerfile.dev`: `apt-get install` に `chromium fonts-noto-cjk` を追加（`food_vault` とイメージを共有するため、在庫側のイメージも大きくなる。分けるのは今回の範囲外）。本番イメージ（`infra/`・Cloud Run）への Chromium・非 root 実行は**残課題**として tasklist に記録する
- `config/config.exs`: `config :food_ship, FoodShip.Utils.Pdf, adapter: FoodShip.Utils.Pdf.Chromic, start: true`。`config/test.exs`: `adapter: FoodShip.Utils.Pdf.Fake, start: false`。`config/dev.exs`: `no_sandbox: true`。`config/runtime.exs`: `PDF_POOL_SIZE`・`PDF_TIMEOUT_MS`・`PDF_CHROME_PATH`
- `FoodShip.Application`: `Pdf.child_specs/0` を子に足す（`start: false` なら空）

## 9. テスト方針

- Context（`total_picks_test.exs`）: 作成（グループ分け・`allocated` 以外とピック済みを除外・追加ピック・選択が空・対象 0 件でロールバック・`viewer` は拒否）、`release/2`（`issued → outdated`・最後の 1 件で `cancelled`）、再発行（`revision` 加算・`outdated` 以外は拒否・伝票 0 件は拒否）、取消（`packed` を含むと拒否・伝票が未ピックに戻る）、集計（期限日ごとの合算・期限なし・梱包済みを含む・件数/箱数は商品単位）
- 並行性（`ConcurrencyCase`）: 同じ伝票に対する `create_total_picks` を 2 つ同時に実行して、片方だけ成功する。取消と数量変更の同時実行でデッドロックしない
- `ShippingSlips`（既存テストに追記）: 数量変更・出荷予定日変更・取消で伝票がピックから外れてピックが `outdated`／`cancelled`、梱包完了ではピックも `total_pick_id` も変わらない
- LiveView: 作業画面（ピック番号・未ピックのみ・作成ダイアログ・`viewer` に操作が出ない・イベント直接送信の拒否）、一覧・詳細（絞り込み・表示・再発行・取消）
- Controller: 認可（未ログイン→ログイン画面、`viewer` 拒否）、`issued` で `application/pdf`、`outdated` / `cancelled` でリダイレクトとフラッシュ、作業指示書の状態ごとの応答、`Fake` が返した HTML に外部 URL（`http://`・`https://`・`src=`・`url(`）が無いこと
- `Pdf`（`@tag :pdf`）: 実 Chromium で日本語を含む HTML から `%PDF` を得る。`PDF_TEST=1` のときだけ実行

## 10. 影響範囲・リスク

- DB: `shipping_slips` に NULL 可の列と CHECK を追加（CHECK は既存行すべてが `total_pick_id IS NULL` なので満たされる）。`food_vault` と API の契約には影響しない
- 既存テスト: `preload_slip` に `:total_pick` を足すので、伝票を構造体比較しているテストがあれば調整する
- 日本語の見え方・A4 への収まり・改ページは実機の PDF（画像にレンダリングして目視）で確認する。sandbox 環境の Chromium とフォントの有無に依存するため、確認できなかった場合は tasklist に記録する
