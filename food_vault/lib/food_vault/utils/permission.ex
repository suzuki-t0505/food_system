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
    emergency_ship_order: :admin,
    # メーカー・倉庫・商品の編集・アーカイブ・復帰
    manage_masters: :admin,
    # 入荷登録
    receive_inventory: :staff,
    # 画面登録オーダーの登録・出庫確定・引当解除
    manage_shipment_order: :staff,
    # 棚卸調整(入荷訂正・荷まとめを含む)
    adjust_inventory: :admin
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

  @doc """
  Context 内の権限検査。`:ok` または `{:error, :forbidden}` を返す。

  操作者(actor)は画面のユーザー(`%{role: _}`)か、在庫 API の `{:api, operator}`。
  API はサービストークンで認証済みで、ロールの判定は呼び出し側の責任なので許可する。
  """
  @spec authorize(term(), atom()) :: :ok | {:error, :forbidden}
  def authorize({:api, operator}, _action) when is_binary(operator), do: :ok

  def authorize(user, action) do
    if can?(user, action), do: :ok, else: {:error, :forbidden}
  end

  defp rank(role), do: Enum.find_index(@roles, &(&1 == role))
end
