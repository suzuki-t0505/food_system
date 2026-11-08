# FoodShip

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## 在庫システムとの連携(開発)

在庫 API の接続先とトークンは `config/runtime.exs` の既定値(`http://food_vault_web:4000`、`dev-inventory-api-token`)で動く。

引当先の倉庫は環境変数では指定せず、**在庫システムのデフォルト倉庫**を使う。在庫の倉庫画面(`/masters/warehouses`)で、`admin` が「デフォルトにする」で設定する。
未設定の間は、伝票登録・再引当・数量変更を拒否して作業画面に警告を出す(在庫の dev seeds は `W01` をデフォルトにする)。

| 環境変数 | 内容 | 必須 |
| :-- | :-- | :-- |
| `INVENTORY_API_BASE_URL` | 在庫 API のベース URL | 本番は必須 |
| `INVENTORY_API_TOKEN` | 在庫 API のサービストークン(在庫側 `INVENTORY_API_TOKENS` のいずれか) | 本番は必須 |
| `INVENTORY_API_CONNECT_TIMEOUT_MS` / `INVENTORY_API_RECEIVE_TIMEOUT_MS` | タイムアウト(既定 5000 / 15000) | 任意 |

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
