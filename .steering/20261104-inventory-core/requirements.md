# 要求内容: 在庫側の核(段階 2)

- 根拠: [development-guidelines.md §1.4](../../docs/development-guidelines.md)(段階 2)、[product-requirements.md F-V1・V2・V3・V5・V6](../../docs/product-requirements.md)、[functional-design.md §2・§3.1・§4.1・§5・§8.1・§9.3](../../docs/functional-design.md)、[architecture.md](../../docs/architecture.md)
- 対象アプリ: `food_vault`(在庫)のみ。`food_ship` は変更しない(段階 4)
- 位置づけ: 段階 1(認証・`current_scope`・認可 3 層)の次。段階 3(在庫 API)・段階 4(発送側)はこの Context を呼ぶだけにできる状態を目指す
- 進め方: 作業単位が大きいため、下記の **5 つの作業単位を順に**実装し、単位ごとに `make check` を通してコミットする

## 背景

`food_vault` には認証・ユーザーしかなく、業務テーブル・Context・画面が一切ない。`Permission` には `emergency_ship_order` のみが定義済みで、`Utils.Calc` は未作成。

## 要求(スコープ)

### 作業単位 A: マスタ管理(F-V1)

- テーブル `makers`・`warehouses`・`items`(functional-design §3.1)。ID は ULID、`archived_at` で論理削除、FK は `on_delete: :nothing`
- 画面: メーカー・倉庫・商品の一覧と登録・編集・アーカイブ・復帰。参照は全ロール、編集・アーカイブ・復帰は `admin`(`/management/...`)
- 商品は `units_per_case`(1 以上)と `expiration_type`(`consumption` / `best_before` / `none`)を持つ
- ロット(在庫 0 を含む)がある商品は、`units_per_case` と `expiration_type` を変更できない(`items` 行を `FOR UPDATE` で読んでから検査。作業単位 B で入荷側が `FOR SHARE` を取り、競合しない)
- アーカイブ規則(§5.9): 商品=全ロールが在庫 0 かつ `allocated` オーダー明細に含まれない、倉庫=全ロールが在庫 0・引当なし、メーカー=有効な商品を持たない。アーカイブ済みは選択肢に出さない
- 商品コード・メーカーコード・倉庫コードは一意

### 作業単位 B: 入荷・在庫一覧・受払履歴(F-V2・F-V6)

- テーブル `inventory_lots`(UNIQUE・CHECK は §3.1 のとおり)と `inventory_transactions`(追記専用、CHECK `user_id IS NOT NULL OR operator IS NOT NULL`)
- 入荷登録(`staff` 以上): 倉庫・商品・期限日・入荷日・ケース数・バラ数。期限区分 `none` 以外は期限日必須、`none` は `9999-12-31` で保存し画面では「期限なし」。`INSERT ... ON CONFLICT DO UPDATE` で原子的に加算し、`receive` を操作者付きで記録する(§5.2)
- 入力欄の下に総バラ数(`総数:〇〇 個`)をリアルタイム表示する。計算は `FoodVault.Utils.Calc` に集約(§5.10)
- 在庫一覧(全ロール): 倉庫・商品・期限で絞り込み、ロット別／商品別に `ケース数 | バラ数 | 総バラ数`・引当済・有効在庫を期限の近い順に表示。在庫 0 は既定で非表示。ロット詳細は作業単位 D・E で引当オーダーを足す
- 受払履歴(全ロール): ロット・商品・期間・処理区分・操作者で検索。出庫オーダー・移動ペアへのリンクを持つ。更新・削除の経路を作らない

### 作業単位 C: 出庫オーダーの引当(F-V3 前半)

- テーブル `shipment_orders`・`shipment_order_lines`・`shipment_allocations`・`shipment_order_events`(追記専用)
- 引当の Context 関数(§5.3): 先出し順(期限日 → 入荷日 → ロット ID)、出庫可能期限、ケース要求→バラ要求の 2 ステップ、同一ロット内の自動荷崩し(`auto_break` を 1 ロット 1 行)、不足が 1 つでもあれば全体ロールバックして**全明細分**の不足数を返す
- ロック順(§5.1): `items` を `item_id` 昇順で `FOR SHARE` → 触るロットを 1 クエリで `FOR UPDATE`(ロックキー昇順)、明細は `item_id` 昇順で処理。DB の CHECK で引当済数が現在庫を超えないことも担保
- `external_slip_id` の冪等(Context 層): `cancelled` 以外の同一 ID があれば、内容一致なら既存を返し、不一致は `{:error, :idempotency_conflict}`。冪等な再送ではイベントを追加しない。API の HTTP 化は段階 3
- 画面: 出庫オーダー一覧・詳細・登録(参照は全ロール、登録は `staff` 以上。画面登録のオーダーは `external_slip_id` なし)。詳細に引当ロットとオーダー履歴を表示

### 作業単位 D: 出庫確定・引当解除(F-V3 後半)

- 出庫確定(§5.4): 引当ロットを 1 クエリでロックし、現在庫と引当済数を減算、`ship` と `shipped` を記録
- 引当解除(§5.5): 引当済数のみ減算(現在庫は不変)、オーダーを `cancelled`、引当明細は残す、`cancelled` を記録。確定・解除は現状態なら冪等に成功を返す
- 画面: 詳細から確定・取消(`staff` 以上、`handle_event` 先頭で `Permission.can?/2`)
- 発送システム起源(`external_slip_id` あり)のオーダーの画面での確定・解除は**拒否**する(緊急操作 F-V8 は P1 のためスコープ外)。Context 関数は呼び出し元(API・画面)を問わず使える形にする

### 作業単位 E: 棚卸調整(F-V5)

- 画面(`admin`、`/management/...`): ロット指定でケース数・バラ数を増減。理由必須。受払履歴 `adjust`
- 有効在庫(現在庫 − 引当済)を下回る減算は不可。入荷訂正(期限日・入荷日の誤りは「全数減算 → 再入荷」)と荷まとめ(`case_diff = +k`・`piece_diff = -k × units_per_case`)を 1 回の調整として登録できる
- ロット詳細に、そのロットを引き当てているオーダーを表示する

### 共通

- 権限表(§9.3)を `Permission` に追加: 入荷登録・画面オーダー操作・移動は `staff`、棚卸調整・マスタ編集は `admin`。判定は `Permission.can?/2` に一本化し、`live_session` には `on_mount` を指定する
- すべての更新は `Repo.transact/1`(`Ecto.Multi`)の単一トランザクション。書き込み操作は `OperationLog` に操作ユーザーを記録する
- 全ロットに対する数量は整数、DB に CHECK で不変条件を持たせる

## 受け入れ条件

- [x] **A**: メーカー・倉庫・商品を `admin` が作成・編集でき、`staff`・`viewer` は参照のみ(plug・`on_mount`・`handle_event` で拒否)。コードの重複が弾かれる
- [x] **A**: ロットがある商品の `units_per_case`・`expiration_type` 変更が拒否される。アーカイブ規則(商品・倉庫・メーカー)が §5.9 のとおり働き、アーカイブ済みは選択肢に出ない
- [x] **B**: 入荷登録で新規ロット作成と加算の両方が動き、同時入荷でも加算が失われない(並行テストあり)。`none` 商品は `9999-12-31` で保存され「期限なし」と表示される
- [x] **B**: 総バラ数がリアルタイム表示される。在庫一覧のフィルタ・並び順・在庫 0 非表示・3 列表示が動く
- [x] **B/F-V6**: 受払履歴に操作者付きで記録され、検索できる。更新・削除の関数が存在しない
- [x] **C**: 先出し順・出庫可能期限・荷崩し(`auto_break` 1 行)・不足時の全体ロールバックと全明細分の不足数が、テストで確認できる
- [x] **C**: 同一商品への同時引当で引当済数が現在庫を超えない(並行テスト、CHECK 制約)。複数明細・複数オーダーが同時に走ってもデッドロックしない
- [x] **C**: 同じ `external_slip_id` の再送が、一致なら既存を返し、不一致は `idempotency_conflict`
- [x] **D**: 確定で現在庫と引当済数が減り `ship`・`shipped` が残る。解除で引当済数のみ戻り `cancelled` が残り、引当明細は残る。繰り返し実行しても同じ結果
- [x] **D**: 発送システム起源オーダーの画面での確定・解除が拒否される
- [x] **E**: `admin` のみが調整でき、理由なし・有効在庫を下回る減算は拒否される。荷まとめと入荷訂正が 1 回の調整で登録できる
- [x] 画面のロール別の許可・拒否テストがある。`make check`(compile 警告ゼロ・format 差分なし・credo・test)が `food_vault` で通り、`food_ship` に影響しない

## スコープ外

- 在庫 API(`/api/v1`)・サービストークン・共通エラー形式(段階 3)
- 出庫取消(F-V7)、緊急操作(F-V8)、倉庫間移動(F-V9)(いずれも P1)。移動用の `transfer_in` / `transfer_out` / `transfer_id` は列・enum のみ用意し、操作は作らない
- `ship_reverse`(F-V7)は enum 値だけ用意する
- CSV 取込・PDF 帳票・期限アラート(P1/P2)
- `food_ship` の変更

## 決定事項

- 1 つのステアリングで段階 2 全体を扱い、作業単位 A〜E の順に実装・検証・コミットする(単位ごとに tasklist を更新)
- ステアリング文書は requirements → design → tasklist の順に 1 ファイルずつ承認を得る

## 未確定(design.md で決める)

- Context の分割(`Masters` / `Inventory` / `Shipments` など)と公開関数の形、戻り値(`{:error, {:shortage, ...}}` の形)
- ロット・受払履歴の一覧のページング方式
- 入荷日の既定値、画面の URL 体系、`seeds.exs` の開発用マスタデータの有無
- 並行テストの方式(`Ecto.Adapters.SQL.Sandbox` の `:shared` と複数プロセス)
