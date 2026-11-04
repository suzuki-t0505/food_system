defmodule FoodVault.Accounts.User do
  @moduledoc """
  ユーザー。管理者が登録する(自己登録なし)。削除せず `archived_at` でアーカイブする。

  changeset は用途別に分ける。

    * `create_changeset/3` - 管理者による登録
    * `password_changeset/3` - 本人によるパスワード変更(現在のパスワード必須)
    * `reset_password_changeset/3` - 管理者によるパスワード再設定
    * `role_changeset/2` / `archive_changeset/1` / `restore_changeset/1` - 管理者による状態変更
  """

  use FoodVault.Schema
  import Ecto.Changeset

  @roles [:viewer, :staff, :admin]
  @role_labels %{admin: "管理者", staff: "担当者", viewer: "閲覧者"}

  @derive {Inspect, except: [:password, :current_password, :hashed_password]}
  schema "users" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :role, Ecto.Enum, values: @roles, default: :viewer
    field :must_change_password, :boolean, default: true
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "ロールの一覧(権限の弱い順)。"
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "ロールの表示名。"
  @spec role_label(atom()) :: String.t()
  def role_label(role), do: Map.fetch!(@role_labels, role)

  @doc "アーカイブ済みか。"
  @spec archived?(%__MODULE__{}) :: boolean()
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc """
  管理者によるユーザー登録。`must_change_password` は常に true にする。

  ## Options

    * `:validate_unique` - false にするとメールの一意性を検証しない(画面の即時検証用)
    * `:hash_password` - false にするとパスワードをハッシュ化しない(画面の即時検証用)
  """
  def create_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :name, :role, :password])
    |> validate_required([:name, :role])
    |> validate_length(:name, max: 100)
    |> validate_email(opts)
    |> validate_password(opts)
    |> put_change(:must_change_password, true)
  end

  @doc """
  本人によるパスワード変更。現在のパスワードが必要で、変更後は `must_change_password` が false になる。
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:current_password, :password])
    |> validate_confirmation(:password, message: "が一致しません。")
    |> validate_required([:current_password], message: "を入力してください。")
    |> validate_current_password(user)
    |> validate_password_rules()
    |> validate_password_changed(user)
    |> maybe_hash_password(opts)
    |> put_change(:must_change_password, false)
  end

  @doc "管理者によるパスワード再設定。`must_change_password` を true にする。"
  def reset_password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_password(opts)
    |> put_change(:must_change_password, true)
  end

  @doc "ロール変更。"
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end

  @doc "アーカイブ。"
  def archive_changeset(user) do
    change(user, archived_at: DateTime.utc_now(:second))
  end

  @doc "アーカイブからの復帰。"
  def restore_changeset(user), do: change(user, archived_at: nil)

  @doc """
  パスワードを検証する。ユーザーが無い場合も `Bcrypt.no_user_verify/0` で時間差を作らない。
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_user, _password) do
    Bcrypt.no_user_verify()
    false
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> update_change(:email, &String.trim/1)
      |> validate_required([:email], message: "を入力してください。")
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "の形式が正しくありません。")
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, FoodVault.Repo, message: "はすでに使われています。")
      |> unique_constraint(:email, message: "はすでに使われています。")
    else
      changeset
    end
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_password_rules()
    |> maybe_hash_password(opts)
  end

  defp validate_password_rules(changeset) do
    changeset
    |> validate_required([:password], message: "を入力してください。")
    |> validate_length(:password, min: 12, message: "は12文字以上で入力してください。")
    |> validate_length(:password, max: 72, count: :bytes, message: "が長すぎます。")
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
      |> delete_change(:current_password)
    else
      changeset
    end
  end

  defp validate_current_password(changeset, user) do
    case get_change(changeset, :current_password) do
      nil ->
        changeset

      current_password ->
        if valid_password?(user, current_password) do
          changeset
        else
          add_error(changeset, :current_password, "が正しくありません。")
        end
    end
  end

  defp validate_password_changed(changeset, user) do
    password = get_change(changeset, :password)

    if password && changeset.valid? && valid_password?(user, password) do
      add_error(changeset, :password, "は現在のパスワードと異なるものにしてください。")
    else
      changeset
    end
  end
end
