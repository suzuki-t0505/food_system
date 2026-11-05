defmodule FoodVaultWeb.Api.Operator do
  @moduledoc """
  状態を変える在庫 API(①②③)の `operator`(操作者)と、任意の `reason` の検証。

  `operator` は必須で、受払履歴・オーダー履歴に残る。文字列で、前後の空白を除いて空でなく、
  255 文字以内。違反は `{:error, :validation_failed, errors}`(`errors` は
  `FoodVault.ShipmentOrders.Request` と同じ `[%{path: [...], message: "..."}]`)。
  """

  @max_length 255

  @doc "`params` から `operator` を取り出す。"
  @spec fetch(map()) :: {:ok, String.t()} | {:error, :validation_failed, [map()]}
  def fetch(params) do
    case params["operator"] do
      value when is_binary(value) -> validate_operator(String.trim(value))
      nil -> invalid("operator", "を指定してください")
      _ -> invalid("operator", "は文字列で指定してください")
    end
  end

  @doc "`params` から任意の `reason` を取り出す。未指定・空白のみは `nil`。"
  @spec fetch_reason(map()) :: {:ok, String.t() | nil} | {:error, :validation_failed, [map()]}
  def fetch_reason(params) do
    case params["reason"] do
      nil -> {:ok, nil}
      value when is_binary(value) -> validate_reason(String.trim(value))
      _ -> invalid("reason", "は文字列で指定してください")
    end
  end

  defp validate_operator(""), do: invalid("operator", "を指定してください")

  defp validate_operator(value) do
    if String.length(value) > @max_length,
      do: invalid("operator", "は #{@max_length} 文字以内で指定してください"),
      else: {:ok, value}
  end

  defp validate_reason(""), do: {:ok, nil}

  defp validate_reason(value) do
    if String.length(value) > @max_length,
      do: invalid("reason", "は #{@max_length} 文字以内で指定してください"),
      else: {:ok, value}
  end

  defp invalid(field, message),
    do: {:error, :validation_failed, [%{path: [field], message: message}]}
end
