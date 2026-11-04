defmodule FoodShip.Accounts.UserToken do
  @moduledoc """
  セッショントークン。`session` コンテキストのみ。

  セッション cookie は署名のみで失効できないため、トークンを DB に保存し、
  行を削除することでセッションを即時に失効させる。
  """

  use FoodShip.Schema
  import Ecto.Query

  alias FoodShip.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    belongs_to :user, FoodShip.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "セッショントークンを作る。`{token, %UserToken{}}` を返す(保存は呼び出し側)。"
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  トークンからユーザーを引くクエリ。`{user, token の inserted_at}` を返す。

  有効期間内で、ユーザーがアーカイブされていないトークンのみ有効。
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        where: is_nil(user.archived_at),
        select: {user, token.inserted_at}

    {:ok, query}
  end

  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  def by_user_query(user_id) do
    from UserToken, where: [user_id: ^user_id]
  end
end
