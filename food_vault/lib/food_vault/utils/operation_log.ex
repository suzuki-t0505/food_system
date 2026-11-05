defmodule FoodVault.Utils.OperationLog do
  @moduledoc """
  操作ログ。「誰が・いつ・どのページで・どのデータで・何をしたか」を 1 行で残す。

      OperationLog.info(socket, "品目を登録しました。", :create, item)
      OperationLog.info(conn, "品目を更新しました。", :update, item)

  - 書き込みが**成功したときだけ**呼ぶ (`{:error, changeset}` の節では呼ばない)
  - `Task` の中では呼ばず、結果を受ける `handle_info` の成功節で呼ぶ
  - 第 4 引数は書き込み結果をそのまま渡す。機微データは `FoodVault.Utils.Logger.normalize/1` が除く
  - カテゴリは `:create` / `:update` / `:delete` のみ (アーカイブ・承認などは DB 上 update なので `:update`)
  """

  alias FoodVault.Utils.Logger, as: AppLogger

  @categories [:create, :update, :delete]

  @spec info(Phoenix.LiveView.Socket.t() | Plug.Conn.t(), String.t(), atom(), term()) :: :ok
  def info(target, message, category, data) when category in @categories do
    require Elixir.Logger

    Elixir.Logger.info(%{
      message: message,
      category: AppLogger.category_name!(category),
      variable: %{
        operator: operator(target),
        page: page(target),
        data: AppLogger.normalize(data)
      }
    })
  end

  # current_scope は認証の実装 (段階 1) で入る。ある場合だけ操作者の ID を取り出す
  defp operator(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id

  # 在庫 API はユーザーでなく、リクエストの operator(発送システムの操作者)を記録する
  defp operator(%{assigns: %{api_operator: operator}}) when is_binary(operator), do: operator
  defp operator(_target), do: nil

  defp page(%Phoenix.LiveView.Socket{view: view, assigns: assigns}) do
    case assigns do
      %{live_action: action} when not is_nil(action) -> "#{inspect(view)} (#{action})"
      _ -> inspect(view)
    end
  end

  defp page(%Plug.Conn{request_path: path}), do: path
  defp page(_target), do: nil
end
