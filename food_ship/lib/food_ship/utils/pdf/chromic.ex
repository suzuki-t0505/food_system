defmodule FoodShip.Utils.Pdf.Chromic do
  @moduledoc """
  ChromicPDF(ヘッドレス Chromium)による PDF 生成。A4 縦・背景あり。

  設定(`config :food_ship, FoodShip.Utils.Pdf`):

    * `pool_size` - 同時に印刷できる数(セッションプールの大きさ)
    * `timeout` - 1 回あたりの印刷のタイムアウト(ミリ秒)
    * `chrome_executable` - Chromium の実行パス(省略時は PATH から探す)
    * `no_sandbox` - `true` のときサンドボックスを無効にする。**root で動く開発環境に限る**。
      本番は設定しない(`runtime.exs` でも読まない)

  プールが埋まっていて待ち切れないときは `{:error, :busy}` を返す。
  """

  @behaviour FoodShip.Utils.Pdf

  @print_options %{
    paperWidth: 8.27,
    paperHeight: 11.69,
    preferCSSPageSize: true,
    printBackground: true
  }

  @impl true
  def child_specs(opts) do
    chromic_opts =
      [
        session_pool: [
          size: Keyword.get(opts, :pool_size, 2),
          timeout: Keyword.get(opts, :timeout, 30_000)
        ],
        no_sandbox: Keyword.get(opts, :no_sandbox, false)
      ]
      |> put_if(:chrome_executable, Keyword.get(opts, :chrome_executable))

    [{ChromicPDF, chromic_opts}]
  end

  @impl true
  def render(html) do
    case ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: @print_options) do
      # 既定の出力は Base64 文字列
      {:ok, base64} when is_binary(base64) -> decode(base64)
      {:error, reason} -> {:error, classify(reason)}
    end
  catch
    # プールの待ち切れ(NimblePool の checkout タイムアウト)
    :exit, {:timeout, _} -> {:error, :busy}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp decode(base64) do
    case Base.decode64(base64) do
      {:ok, "%PDF" <> _ = pdf} -> {:ok, pdf}
      _ -> {:error, :invalid_pdf}
    end
  end

  defp classify({:timeout, _}), do: :busy
  defp classify(reason), do: reason

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
