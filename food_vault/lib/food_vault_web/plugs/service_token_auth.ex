defmodule FoodVaultWeb.Plugs.ServiceTokenAuth do
  @moduledoc """
  在庫 API のサービストークン認証。`Authorization: Bearer <token>` を検証する。

  トークンは `config :food_vault, #{inspect(__MODULE__)}, tokens: [...]`
  (環境変数 `INVENTORY_API_TOKENS`、`config/runtime.exs`)。複数登録でき、ローテーションは
  「新トークンを追加 → 発送側を切り替え → 旧トークンを削除」で行う。

  不一致・欠落は 401 `unauthorized` で `halt` する。トークンの値と `Authorization` ヘッダは
  ログに出さない。トークンの照合は `valid_token?/1` に閉じ込めてあり、将来 DB 発行・有効期限に
  変えるときはここだけを差し替える(Controller・Context は認証方式を知らない)。
  """

  @behaviour Plug

  import Plug.Conn

  use FoodVault.Utils.Logger

  alias FoodVaultWeb.Api.ErrorResponse

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         true <- valid_token?(token) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  トークンが登録済みか。登録された全トークンと定数時間で比較する。

  一致した時点で打ち切らず、全件を比べてから判定する(一致した位置を応答時間に出さない)。
  """
  @spec valid_token?(term()) :: boolean()
  def valid_token?(token) when is_binary(token) and token != "" do
    :food_vault
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:tokens, [])
    |> Enum.map(&Plug.Crypto.secure_compare(&1, token))
    |> Enum.any?()
  end

  def valid_token?(_token), do: false

  defp bearer_token(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token = String.trim(token),
         true <- token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    Logger.warning("サービストークン認証に失敗しました。", :api, %{path: conn.request_path})

    body = ErrorResponse.body("unauthorized", "認証に失敗しました。")

    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> Phoenix.Controller.json(body)
    |> halt()
  end
end
