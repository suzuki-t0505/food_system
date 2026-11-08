defmodule FoodShip.Utils.Permission do
  @moduledoc """
  権限判定。`can?/2` に一本化し、ボタン表示とイベント処理の両方で同じ関数を呼ぶ。

  ロールは `viewer < staff < admin` で、上位ロールは下位ロールの操作を含む。
  `required_roles/0` は権限表と 1 対 1 に対応させる。定義されていないアクションは**拒否**する。
  """

  @roles [:viewer, :staff, :admin]

  # アクション => 許可する最低ロール。モジュール属性にすると型チェッカが警告するため関数で返す
  defp required_roles do
    %{
      # 自分のパスワード変更(全ロール)
      change_own_password: :viewer,
      # ユーザー管理(登録・ロール変更・パスワード再設定・アーカイブ)
      manage_users: :admin,
      # 発注元・発送商品・出荷期限ルールの編集・アーカイブ・再取得
      manage_masters: :admin,
      # 伝票登録・再引当・数量変更・取消
      manage_shipping_slips: :staff,
      # 箱数の修正・梱包完了
      pack_shipping_slips: :staff,
      # トータルピックの作成・再発行・取消、帳票(PDF)の出力
      manage_total_picks: :staff
    }
  end

  @doc "ユーザーが `required` 以上のロールを持つか。"
  @spec role_at_least?(term(), atom()) :: boolean()
  def role_at_least?(%{role: role}, required) when role in @roles and required in @roles do
    rank(role) >= rank(required)
  end

  def role_at_least?(_user, _required), do: false

  @doc "ユーザーがアクションを実行できるか。"
  @spec can?(term(), atom()) :: boolean()
  def can?(user, action) do
    case Map.fetch(required_roles(), action) do
      {:ok, required} -> role_at_least?(user, required)
      :error -> false
    end
  end

  @doc "Context 内の権限検査。`:ok` または `{:error, :forbidden}` を返す。"
  @spec authorize(term(), atom()) :: :ok | {:error, :forbidden}
  def authorize(user, action) do
    if can?(user, action), do: :ok, else: {:error, :forbidden}
  end

  defp rank(role), do: Enum.find_index(@roles, &(&1 == role))
end
