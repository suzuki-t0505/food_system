# FoodShip

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## 在庫システムとの連携(開発)

在庫 API の接続先とトークンは `config/runtime.exs` の既定値(`http://food_vault_web:4000`、`dev-inventory-api-token`)で動く。
**対象倉庫の ID(`INVENTORY_WAREHOUSE_ID`)だけは設定が必要**で、未設定の間は伝票登録・再引当を拒否する。

1. 在庫システムを起動し、seeds で倉庫を作る(`make setup` 済みなら作成済み)
2. 在庫 API で倉庫の ID を確認する

   ```bash
   curl -H "Authorization: Bearer dev-inventory-api-token" http://localhost:4000/api/v1/warehouses
   ```

3. 環境変数に設定して起動する(例: `INVENTORY_WAREHOUSE_ID=01J... docker compose up -d food_ship_web`)

| 環境変数 | 内容 | 必須 |
| :-- | :-- | :-- |
| `INVENTORY_API_BASE_URL` | 在庫 API のベース URL | 本番は必須 |
| `INVENTORY_API_TOKEN` | 在庫 API のサービストークン(在庫側 `INVENTORY_API_TOKENS` のいずれか) | 本番は必須 |
| `INVENTORY_WAREHOUSE_ID` | 対象倉庫の ID | 任意(未設定なら伝票登録・再引当を拒否) |
| `INVENTORY_API_CONNECT_TIMEOUT_MS` / `INVENTORY_API_RECEIVE_TIMEOUT_MS` | タイムアウト(既定 5000 / 15000) | 任意 |

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
