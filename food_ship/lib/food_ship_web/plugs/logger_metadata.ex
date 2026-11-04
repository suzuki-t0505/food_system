defmodule FoodShipWeb.Plugs.LoggerMetadata do
  @moduledoc """
  Logger のメタデータに `remote_ip` を設定する。`Plug.RequestId` の直後に置く。

  リバースプロキシ配下の送信元 IP (`X-Forwarded-For`) は扱わない (本番構成の決定後に見直す)。
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Elixir.Logger.metadata(remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string())
    conn
  end
end
