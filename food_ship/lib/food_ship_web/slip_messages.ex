defmodule FoodShipWeb.SlipMessages do
  @moduledoc """
  伝票の引当・梱包・取消の結果(`FoodShip.ShippingSlips` の戻り値)を画面の文言にする。

  文言は functional-design §6.3・§9 に揃える。一時エラーは「再引当を押してください」、
  恒久エラーは「設定またはマスタを確認してください」と区別する。
  """

  alias FoodShip.ShippingSlips.ShippingSlip

  @error_labels %{
    connection: "通信エラー",
    unauthorized: "在庫システムの認証エラー",
    not_found: "在庫システムに商品が見つかりません",
    validation_failed: "在庫システムが入力内容を受け付けません",
    idempotency_conflict: "在庫システムに内容の異なるオーダーがあります"
  }

  @doc "引当エラーの種別の表示名。"
  def error_label(error), do: Map.fetch!(@error_labels, error)

  @doc """
  `pending` の行に出す引当エラーの説明。一時エラーと恒久エラーで文言を分ける。
  引当エラーが無ければ `nil`。
  """
  def pending_message(%ShippingSlip{allocation_error: nil}), do: nil

  def pending_message(%ShippingSlip{allocation_error: error}) do
    if ShippingSlip.transient_error?(error) do
      "通信に失敗しました。再引当を押してください。"
    else
      "再試行しても直りません。設定またはマスタを確認してください(原因: #{error_label(error)})"
    end
  end

  @doc """
  引当・再引当(`allocate_shipping_slip/2`)の結果。`{:info | :error, 文言}` を返す。

  `{:ok, slip, info}` の `info` は `errors`(422 `validation_failed` の内容)・`reconciled`
  (在庫側の出庫済みに合わせて `packed` にした)を持つことがある。
  """
  def allocation_result({:ok, %ShippingSlip{status: :allocated}, _info}),
    do: {:info, "引き当てました。"}

  def allocation_result({:ok, %ShippingSlip{status: :shortage} = slip, _info}),
    do: {:error, "在庫が不足しています(不足 #{slip.shortage_pieces} 個)。入荷後に再引当してください。"}

  def allocation_result({:ok, %ShippingSlip{status: :packed}, _info}),
    do: {:info, "在庫側の出庫済みに合わせて、梱包完了に更新しました。"}

  def allocation_result({:ok, %ShippingSlip{status: :pending} = slip, info}) do
    detail =
      case info do
        %{errors: [_ | _] = errors} -> "(" <> Enum.map_join(errors, "、", & &1.message) <> ")"
        _ -> ""
      end

    {:error, (pending_message(slip) || "引当が完了していません。") <> detail}
  end

  def allocation_result({:error, reason}), do: {:error, error_message(reason)}

  @doc "操作の失敗(`{:error, reason}`)の文言。在庫 API のエラーも含む。"
  def error_message(:forbidden), do: "権限がありません。"
  def error_message(:stale), do: "他の操作で更新されました。画面を読み込み直します。"
  def error_message(:invalid_status), do: "現在の状態では、この操作はできません。"
  def error_message(:warehouse_not_configured), do: "対象倉庫が設定されていません。管理者に連絡してください。"
  def error_message(:connection), do: "在庫システムに接続できませんでした。時間をおいて、もう一度お試しください。"
  def error_message(:unauthorized), do: "在庫システムの認証に失敗しました。管理者に連絡してください。"
  def error_message(:not_found), do: "在庫システムに該当のオーダーが見つかりません。"

  def error_message({:remote_state, :shipped}),
    do: "在庫システムではすでに出庫済みです。梱包完了を行って状態を合わせてください。"

  def error_message({:remote_state, status}),
    do: "在庫システムのオーダーの状態(#{status})では、この操作はできません。"

  def error_message(_other), do: "操作に失敗しました。"
end
