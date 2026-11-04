defmodule FoodVault.Utils.Permission do
  @moduledoc """
  権限判定。`can?/2` に一本化し、ボタン表示とイベント処理の両方で同じ関数を呼ぶ。

  ロールは `viewer < staff < admin` で、上位ロールは下位ロールの操作を含む。
  `@required_roles` は権限表と 1 対 1 に対応させる。定義されていないアクションは**拒否**する。
  """

  @roles [:viewer, :staff, :admin]

  # アクション => 許可する最低ロール
  @required_roles %{
    # 自分のパスワード変更(全ロール)
    change_own_password: :viewer,
    # ユーザー管理(登録・ロール変更・パスワード再設定・アーカイブ)
    manage_users: :admin,
    # 発送システム起源オーダーの画面での確定・引当解除
    emergency_ship_order: :admin
  }

  @doc "ユーザーが `required` 以上のロールを持つか。"
  @spec role_at_least?(term(), atom()) :: boolean()
  def role_at_least?(%{role: role}, required) when role in @roles and required in @roles do
    rank(role) >= rank(required)
  end

  def role_at_least?(_user, _required), do: false

  @doc "ユーザーがアクションを実行できるか。"
  @spec can?(term(), atom()) :: boolean()
  def can?(user, action) do
    case Map.fetch(@required_roles, action) do
      {:ok, required} -> role_at_least?(user, required)
      :error -> false
    end
  end

  defp rank(role), do: Enum.find_index(@roles, &(&1 == role))
end
