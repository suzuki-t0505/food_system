defmodule FoodVaultWeb.Plugs.ApiFormat do
  @moduledoc """
  `/api/` 配下のリクエストの応答形式を JSON に固定する。`Plug.Parsers` の前に置く。

  `Accept` ヘッダが無い、または `*/*` のとき、Phoenix は Endpoint レベルのエラー
  (壊れた JSON、存在しないルート)を HTML で返してしまう。API は常に JSON のエラー形式
  (`FoodVaultWeb.ErrorJSON`)で返す。
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    Phoenix.Controller.put_format(conn, "json")
  end

  def call(conn, _opts), do: conn
end
