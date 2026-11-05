defmodule FoodVaultWeb.ErrorJSON do
  @moduledoc """
  Endpoint が JSON のリクエストで起きたエラーを描画するモジュール(config/config.exs)。

  JSON を返すのは在庫 API だけなので、API の共通エラー形式
  (`FoodVaultWeb.Api.ErrorResponse`)で返す。ルーティング前に起きるエラー
  (存在しないルート、壊れた JSON、`Accept` の不一致)がここに来る。

  `Accept` が無い・`*/*` のリクエストでも JSON になるよう、`config/config.exs` の
  `render_errors` は JSON を先頭(fallback)にしている。
  """

  alias FoodVaultWeb.Api.ErrorResponse

  @codes %{
    400 => "bad_request",
    404 => "not_found",
    406 => "not_acceptable",
    413 => "payload_too_large",
    415 => "unsupported_media_type",
    422 => "unprocessable_entity",
    500 => "internal_server_error"
  }

  @messages %{
    400 => "リクエストが正しくありません。",
    404 => "見つかりません。",
    406 => "JSON 以外の形式には対応していません。",
    413 => "リクエストが大きすぎます。",
    415 => "対応していない Content-Type です。",
    422 => "リクエストを処理できません。",
    500 => "サーバーでエラーが発生しました。"
  }

  def render(template, _assigns) do
    status = status(template)

    ErrorResponse.body(
      Map.get(@codes, status) || code(template),
      Map.get(@messages, status) || Phoenix.Controller.status_message_from_template(template)
    )
  end

  defp status(template) do
    case Integer.parse(template) do
      {status, ".json"} -> status
      _ -> nil
    end
  end

  # 上の表に無い状態は、状態名("Bad Gateway")をスネークケースにする
  defp code(template) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
