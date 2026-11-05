defmodule FoodVaultWeb.Api.ErrorResponse do
  @moduledoc """
  在庫 API のエラー応答の本文。全エンドポイントで共通の形式にする。

      %{error: "<code>", message: "<説明>", ...付加情報}

  認証 plug・`FallbackController`・`ErrorJSON`(ルーティング前の 404 や壊れた JSON)が使う。
  """

  @doc "エラー応答の本文を作る。`extra` は付加情報(`shortages`・`errors` など)。"
  @spec body(String.t(), String.t(), map()) :: map()
  def body(code, message, extra \\ %{}) when is_binary(code) and is_binary(message) do
    Map.merge(extra, %{error: code, message: message})
  end
end
