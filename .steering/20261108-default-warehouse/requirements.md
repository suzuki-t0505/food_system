# 要求内容: デフォルト倉庫(vault で管理し、ship は引当先として取得する)

- 根拠: [architecture.md §9・§11](../../docs/architecture.md)、[functional-design.md §6.3・§7.5](../../docs/functional-design.md)、[.steering/20261105-shipping-core](../20261105-shipping-core/design.md)(倉庫 ID を環境変数にした経緯)
- 対象アプリ: `food_vault`(在庫)・`food_ship`(発送)、`infra/terraform`、`docker-compose.yml`、永続ドキュメント

## 背景

発送の対象倉庫は環境変数 `INVENTORY_WAREHOUSE_ID` で渡している。未設定だと伝票登録・再引当・数量変更を拒否し、作業画面に「対象倉庫が設定されていません。管理者に連絡してください。」を表示する。

倉庫の ID は在庫 API(`GET /api/v1/warehouses`)で調べて環境変数や terraform の変数に入れる必要があり、管理者が Web 画面から変更できない。倉庫は在庫側の画面で管理しているので、対象倉庫の指定も同じ画面で完結させたい。

## 要求(スコープ)

### 在庫(food_vault)

- 倉庫に「デフォルト倉庫」の概念を追加する。**デフォルトは常に 0 件または 1 件**
- 倉庫一覧(`/masters/warehouses`)で、`admin` がアーカイブされていない倉庫を「デフォルトにする」で切り替えられる。デフォルトの倉庫にはバッジを表示する。`viewer`・`staff` は参照のみ
- アーカイブ済みの倉庫はデフォルトにできない。デフォルトの倉庫はアーカイブできない(別の倉庫をデフォルトにしてからアーカイブする)
- 在庫 API ⑥(`GET /api/v1/warehouses`)の応答の各倉庫に `is_default` を追加する(後方互換な追加)
- 設定・切り替えは `OperationLog` に記録する

### 発送(food_ship)

- 引当のとき、対象倉庫を環境変数ではなく、在庫 API ⑥ で取得したデフォルト倉庫の ID にする
- デフォルト倉庫が未設定のあいだは、これまでどおり伝票登録・再引当・数量変更を拒否し、警告を出す(`{:error, :warehouse_not_configured}`、文言は現状維持)
- 在庫 API への通信に失敗したときは、「未設定」とは扱わない(警告を出さず、業務操作では既存の通信エラー表示)
- 倉庫を切り替えても、引当済みの既存伝票の引当は変えない。次の再引当から新しいデフォルト倉庫を使う

### 環境変数・インフラの廃止

- `INVENTORY_WAREHOUSE_ID`(`runtime.exs`・`docker-compose.yml`・README)と terraform の `inventory_warehouse_id`(`variables.tf`・`apps.tf`・`terraform.tfvars.example`・README)を**完全に廃止**する。フォールバックとして残さない

### 周辺

- 永続ドキュメント(`architecture.md`・`functional-design.md`・`glossary.md`、影響するもの)を更新する
- テストを追加・更新する(vault: Context・LiveView・API、ship: スタブ・Context・LiveView)

## スコープ外

- デフォルト倉庫の自動設定(最初の倉庫の自動指定、マイグレーションでの設定)。**手動設定のみ**。ただし dev の seeds では動作確認のために設定する
- 複数倉庫からの引当・倉庫の選択・伝票ごとの倉庫指定
- 倉庫を切り替えたときの既存伝票の自動再引当
- 発送側で取得したデフォルト倉庫のキャッシュ(毎回取得する)
- 在庫 API ⑥ 以外の新しいエンドポイント

## 受け入れ条件

- vault でデフォルト倉庫を設定すると、ship の作業画面の警告が消え、伝票登録・再引当でその倉庫に引き当たる
- デフォルトを別の倉庫に切り替えると、次の引当からその倉庫が使われる
- デフォルトが未設定のとき、ship は伝票登録・再引当・数量変更を拒否して警告を出し、DB に保存しない
- デフォルトが 2 件以上にならない(DB の制約と同時実行のテストで確認)
- アーカイブ済みの倉庫のデフォルト化、デフォルト倉庫のアーカイブは拒否される。`viewer`・`staff` はデフォルト設定ができない
- `INVENTORY_WAREHOUSE_ID` と `inventory_warehouse_id` がリポジトリに残っていない(過去の `.steering/` の記録を除く)
- 両アプリで `mix format --check-formatted`・`mix compile --warnings-as-errors`・`mix test` が通る
