# 要求内容: 発送側 P0(段階 4)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 4)、[product-requirements.md F-S1〜F-S4](../../docs/product-requirements.md)、[functional-design.md §3.2・§4.2・§6・§7・§8.2・§9.3](../../docs/functional-design.md)、[architecture.md §3.2・§9・§11](../../docs/architecture.md)
- 対象アプリ: `food_ship`(発送)。`food_vault` は変更しない(段階 3 の在庫 API を呼ぶだけ)
- 位置づけ: 段階 3(在庫 API)の次。段階 1 の認証・認可、段階 0 の基盤(`FoodShip.Schema`・Logger・OperationLog・Permission)の上に、発送側の業務機能を足す

## 背景

`food_ship` はログイン・ユーザー管理だけで、業務テーブル・Context・画面・`Inventory.Client` が無い(`router.ex` は `/` とユーザー管理のみ、`Permission` の業務 action も未定義、`runtime.exs` に `INVENTORY_*` も無い)。在庫側は `/api/v1` の ①②③⑤⑥⑦ が実装済みで、`external_slip_id` による冪等・共通エラー形式・`operator` の記録が使える。`docker-compose.yml` の発送側には `INVENTORY_*` 環境変数が未設定。

## 要求(スコープ)

### F-S1 マスタ管理(functional-design §6.10)

- **発注元**(`clients`): 登録・編集・アーカイブ・復帰。アーカイブ済みは新規伝票の選択肢に出さない
- **発送商品**(`shipping_items`): 商品コード入力で在庫側 ⑦ から `inventory_item_id`・`item_name`・`inventory_maker_id`・`maker_name` を取得して初期入力。`boxes_per_order`(標準箱数)・`pieces_per_order`(商品数量・バラ)を持つ。マスタ画面から在庫側の値を**再取得**できる(自動同期しない)。在庫側の商品と 1 対 1。アーカイブ・復帰
- **出荷期限ルール**(`expiration_rules`): 発注元 × 商品の最低残日数の CRUD(物理削除可)。未登録は制限なし
- 参照は全ロール、編集は `admin` のみ

### F-S2 伝票登録・引当・再引当(§6.1〜§6.3)

- 手入力フォーム(発注元・出荷予定日・商品・件数・任意の発注元伝票番号)。**箱数(手修正可)・出庫総数量(バラ。手修正不可)・最低許容期限日をリアルタイムで計算表示**する
- **先に `pending` で保存(コミット)してから**在庫 ① を呼び、結果で `allocated` / `shortage` / `pending(allocation_error)` に更新する。API はローカル DB のトランザクションの外。画面からは `Task` ＋ `handle_info`
- 応答の引当バラ数の合計が `total_piece_qty` と一致しなければ `allocated` にしない(`allocation_error = validation_failed`)
- 在庫側の応答の扱いは §6.3 の表のとおり(201/200・422 `insufficient_stock`/`validation_failed`・404・409・401・接続エラー)。`pending` の行に `allocation_error`(一時／恒久)と `allocation_attempted_at` を表示
- **再引当**(個別。`pending` / `shortage` の行): §6.2 の手順(最低許容期限日を現在のルールで再計算 → 既存オーダーを照会・解除 → 引当 → 検証)
- `client_slip_no` の部分ユニークで二重登録を防ぐ(画面は「すでに登録されています」)
- `slip_no`(DB シーケンス、`S-000123` 表示)、`slip_allocated_lots`(引当ロットの表示用キャッシュ)

### F-S3 出荷日別の作業画面・数量変更・取消(§6.4〜§6.6)

- 出荷予定日ごとのタブ(残件数 = `pending` / `allocated` / `shortage` の合計)。状態フィルタ(未梱包のみ／在庫不足のみ／すべて)
- 各伝票に、引当ロットの「期限日 × 個数」(期限なしは「期限なし」)を表示。梱包完了後に届いた追加伝票は、同じタブ内で「未梱包」としてハイライト(§6.7)
- **数量・出荷予定日の変更**(`allocated` / `shortage` / `pending`): §6.5 のとおり `pending` に戻して再引当。確認ダイアログに「在庫不足の場合、現在の引当は解除されます」を明記
- **梱包前の取消**: §6.6。`allocated` は ③ 引当解除、`shortage` / `pending` はオーダーがあれば(または照会で見つかれば)解除してから `cancelled`。`cancelled_by_user_id` / `cancelled_at` を保存
- 表示は全ロール、操作は `staff` 以上(`viewer` は参照のみ)

### F-S4 梱包完了(§6.4)

- 「梱包完了」(個別)で確認ダイアログ → ② 出庫確定 → 成功したら `packed`・`packed_at`・`packed_by_user_id`。行をグレーアウト。分割梱包は扱わない
- 実際の箱数が変わったら画面で `box_count` を修正できる(在庫数には影響しない)
- 在庫側が停止している間は失敗して `allocated` のまま(復旧後にやり直せば整合)
- 409 `invalid_state` は ⑤ で照会し、在庫側が `shipped` なら発送側も `packed` に更新。それ以外は最新状態を表示してエラー

### 在庫 API クライアント(architecture §9.1・functional-design §7.5)

- `FoodShip.Inventory.Client`(`Req`)。外部境界モジュール。①②③⑤⑦ を呼び、成功・在庫不足・各エラー・通信失敗をタグ付きタプルに変換する。状態を変える呼び出しは `operator`(画面の操作ユーザーのメール)を必ず付ける
- リトライは `retry: :transient`・最大 3 回・1/2/4 秒。タイムアウトは接続 5 秒・受信 15 秒(設定値)
- 設定は `runtime.exs`: `INVENTORY_API_BASE_URL`・`INVENTORY_API_TOKEN`・`INVENTORY_WAREHOUSE_ID`・`INVENTORY_API_CONNECT_TIMEOUT_MS` / `INVENTORY_API_RECEIVE_TIMEOUT_MS`。本番は必須項目が未設定なら起動時に落とす。dev は既定値あり(段階 3 の dev トークンに合わせる)
- `docker-compose.yml` の発送側に `INVENTORY_*` を追加する(段階 3 で保留した分)

### 認可・画面・周辺

- `Permission` に業務 action を追加(権限表 §9.3 の発送システム。`staff` 以上: 伝票登録・再引当・数量変更・取消・箱数修正・梱包完了、`admin`: マスタ編集)。認可は plug・`on_mount`・イベントの 3 層
- ナビゲーションに業務画面へのリンクを追加。ホーム(`/`)から作業画面へ
- Logger(`:api` カテゴリで在庫 API 呼び出し、トークンは出さない)と `OperationLog`(成功した書き込みのみ。`Task` の中では出さず `handle_info` の成功節で出す)
- 永続ドキュメントへの反映(`architecture.md`・`repository-structure.md`・`development-guidelines.md`・`functional-design.md`・`glossary.md` のうち影響するもの)

## 受け入れ条件

- [ ] F-S1: 発注元・発送商品・出荷期限ルールを `admin` が登録・編集・(アーカイブ)できる。`staff` / `viewer` は参照のみで、イベントを直接送っても拒否される。発送商品は商品コードから在庫側の値を取得でき、再取得で更新できる。在庫側に無い商品コードは画面にエラーを表示する
- [ ] F-S2: 入力値から箱数・バラ数・最低許容期限日が表示され、バラ数は手修正できない。登録すると先に `pending` で保存され、在庫 API の結果で `allocated` / `shortage` / `pending`(`allocation_error`)になる。通信失敗でも入力内容が残る。引当合計が `total_piece_qty` と不一致なら `allocated` にならない。再引当で復旧でき、最低許容期限日が再計算される。二重登録が拒否される
- [ ] F-S3: 出荷予定日タブ・残件数・状態フィルタが動く。引当ロットの「期限日 × 個数」が表示される。数量・出荷予定日の変更(旧引当の解除 → 再引当)、梱包前の取消(実行者・日時の記録)ができる。`viewer` は参照のみ
- [ ] F-S4: 梱包完了で `packed`・梱包完了者・日時が保存される。在庫側停止時は `allocated` のまま失敗し、復旧後のやり直しで整合する。409 は照会して在庫側が `shipped` なら `packed` に更新する。箱数を修正できる
- [ ] `Inventory.Client`: 各 API の成功・各エラー(401/404/409/422)・通信失敗を判別できる。リトライ対象(5xx・接続エラー)と対象外(4xx)が仕様どおり。トークンがログに出ない
- [ ] 例外ケース(§6.11 ①②⑤⑦⑧)がテストで確認できる(在庫不足の保存・通信失敗の `pending` と再引当での復旧・二重登録・在庫側マスタとの不整合・在庫停止中の梱包)
- [ ] テスト: Context(成功系と失敗系・失敗時の DB 状態)、`Inventory.Client`(`Req.Test` のスタブ)、LiveView(画面の表示と DB の書き込み)、認可(ロール別の許可・拒否)。`make check` 相当(compile 警告ゼロ・format 差分なし・credo・test)が `food_ship` で通り、`food_vault` に影響しない

## スコープ外(段階 5 以降)

- **F-S5** CSV 一括取込・一括再引当、**F-S8** 一括梱包完了(今回は個別のみ)
- **F-S6** トータルピック・PDF 帳票(`total_picks` テーブル、`shipping_slips.total_pick_id`、作業画面のピック番号・「未ピックのみ」フィルタ、`ReportController`)。`total_pick_id` 列は段階 5 の migration で追加する
- **F-S7** 梱包完了後の取消(出庫取消。`reversed` 遷移、`reversed_*` 列の運用)。在庫側 ④ が未実装のため。ただし `status` の値 `reversed` と関連列はスキーマに含めるかを design.md で決める
- 「複製して再登録」、伝票の一覧検索(作業画面のタブとフィルタで足りる範囲に限る)
- 在庫側(`food_vault`)の変更、API の契約変更。不足があれば最小限の修正にとどめ tasklist に記録する

## 決定事項

- 1 つのステアリングで段階 4 を扱い、作業単位(基盤・`Inventory.Client` → マスタ → 伝票登録・引当・再引当 → 作業画面・数量変更・取消 → 梱包完了)の順に実装し、単位ごとに品質ゲートを通してコミットする(段階 3 と同じ運び)
- ステアリング文書は requirements → design → tasklist の順に 1 ファイルずつ承認を得る
- 発送側の結合テストは `Req.Test` のスタブで行い、在庫側の実サーバーは使わない(development-guidelines §1.4・§5)

## 未確定(design.md で決める)

- `shipping_slips` のスキーマに `total_pick_id`・`reversed_*` を含めるか(段階 5 の migration に回す前提)と、CHECK 制約の段階的な追加方法
- 画面のルーティング(`/shipping_slips`・`/management/clients` 等)と LiveView の構成(登録フォームを作業画面内のモーダルにするか別画面にするか)
- `operator` を渡す方法(`Client` の引数にメールを渡す。`Task` 内で `socket` を参照しない)
- 非同期処理の粒度(登録直後の引当・再引当・梱包・取消それぞれを `Task` にする方式と、LiveView のロック状態の持ち方)
- `INVENTORY_WAREHOUSE_ID` の dev の既定値(在庫側 seeds の倉庫 ID は実行ごとに変わるため、起動時または初回に在庫 ⑥ で解決する案も含め検討)
- 再引当の「応答を受け取れていない可能性」の判定(`allocation_attempted_at` あり・`inventory_order_id` なしのとき `external_slip_id` で照会する)
