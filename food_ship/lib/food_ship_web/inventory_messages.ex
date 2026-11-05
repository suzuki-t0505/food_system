defmodule FoodShipWeb.InventoryMessages do
  @moduledoc "在庫 API の呼び出し結果(`FoodShip.Inventory.Client` のエラー)を画面の文言にする。"

  @doc "在庫 API のエラーに対応する画面の文言。"
  def error_message(:connection),
    do: "在庫システムに接続できませんでした。時間をおいて、もう一度お試しください。"

  def error_message(:unauthorized),
    do: "在庫システムの認証に失敗しました。設定を確認するよう管理者に連絡してください。"

  def error_message(:not_found), do: "在庫システムに該当する商品が見つかりません。"

  def error_message(:mismatch),
    do: "在庫システムの商品が一致しません。商品コードが変更された場合は、アーカイブして登録し直してください。"

  def error_message(_other), do: "在庫システムとの連携に失敗しました。"
end
