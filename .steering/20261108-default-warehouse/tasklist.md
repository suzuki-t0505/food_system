# タスクリスト: デフォルト倉庫

- 要求: [requirements.md](requirements.md) / 設計: [design.md](design.md)

## 1. vault

- [x] マイグレーション(`warehouses.is_default` ＋ 部分ユニークインデックス)
- [x] `Warehouse` スキーマ(`is_default`・`default_changeset/1`・`default?/1`)
- [x] `Warehouses`(`get_default_warehouse/0`・`set_default_warehouse/2`・デフォルトのアーカイブ拒否)
- [x] `WarehouseLive.Index`(バッジ・「デフォルトにする」・アーカイブ制限・メッセージ)
- [x] `WarehouseJSON` に `is_default`
- [x] `seeds.exs`(dev のみデフォルト設定)
- [x] テスト(Context・LiveView・API・同時実行)
- [ ] `mix format` / `mix compile --warnings-as-errors` / `mix test`(この環境に Elixir が無く未実行)

## 2. ship

- [x] `Inventory.Client.default_warehouse_id/1`(`warehouse_id/0` 削除)
- [x] `ShippingSlips`(`ensure_warehouse/0`・`allocate_remote/3`・`warehouse_configured?/0`)
- [x] `SlipMessages` の確認
- [x] `runtime.exs`・`test.exs` から倉庫 ID を削除
- [x] テストのスタブ(`InventoryStub`)と既存テストの更新
- [ ] `mix format` / `mix compile --warnings-as-errors` / `mix test`(この環境に Elixir が無く未実行)

## 3. インフラ・ドキュメント

- [x] `docker-compose.yml`・`food_ship/README.md`
- [x] `infra/terraform`(`variables.tf`・`apps.tf`・`terraform.tfvars.example`・`README.md`)
- [x] `docs/architecture.md`・`docs/functional-design.md`・`docs/glossary.md`
- [x] `INVENTORY_WAREHOUSE_ID` / `inventory_warehouse_id` の残りを grep で確認(過去の `.steering/` を除く)

## 4. 仕上げ

- [x] コミット・push
- [ ] PR 作成
