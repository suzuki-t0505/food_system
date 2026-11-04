defmodule FoodVaultWeb.Api.FallbackController do
  @moduledoc """
  在庫 API の Controller が `with` で受けた Context のエラーを、共通のエラー形式に変換する。

      { "error": "<code>", "message": "<説明>", ...付加情報 }

  `{:error, :forbidden}` は変換しない(API の操作者はサービストークンで認証済みのため発生しない
  設計で、起きたらクラッシュさせてログに残す)。
  """

  use Phoenix.Controller, formats: [:json]

  alias FoodVaultWeb.Api.ErrorResponse

  def call(conn, {:error, :not_found}) do
    render_error(conn, 404, "not_found", "見つかりません。")
  end

  def call(conn, {:error, :invalid_state}) do
    render_error(conn, 409, "invalid_state", "現在の状態ではこの操作はできません。")
  end

  def call(conn, {:error, :idempotency_conflict, order}) do
    extra = if order, do: %{order_id: order.id, status: Atom.to_string(order.status)}, else: %{}

    render_error(
      conn,
      409,
      "idempotency_conflict",
      "同じ external_slip_id で内容の異なるオーダーがあります。",
      extra
    )
  end

  def call(conn, {:error, :insufficient_stock, shortages}) do
    render_error(conn, 422, "insufficient_stock", "在庫が不足しています。", %{shortages: shortages})
  end

  def call(conn, {:error, :validation_failed, errors}) do
    render_error(conn, 422, "validation_failed", "入力が正しくありません。", %{errors: errors})
  end

  defp render_error(conn, status, code, message, extra \\ %{}) do
    conn
    |> put_status(status)
    |> json(ErrorResponse.body(code, message, extra))
  end
end
