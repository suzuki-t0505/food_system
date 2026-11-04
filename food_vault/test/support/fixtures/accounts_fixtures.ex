defmodule FoodVault.AccountsFixtures do
  @moduledoc "`FoodVault.Accounts` のテスト用データ。"

  alias FoodVault.Accounts.{Scope, User}
  alias FoodVault.Repo

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "hello world!!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      name: "テスト太郎",
      role: :viewer,
      password: valid_user_password()
    })
  end

  @doc """
  ユーザーを作る。`must_change_password` を渡すとその値で保存する(既定は登録直後の true)。
  """
  def user_fixture(attrs \\ %{}) do
    {must_change_password, attrs} = Map.pop(Map.new(attrs), :must_change_password, true)

    user =
      %User{}
      |> User.create_changeset(valid_user_attributes(attrs))
      |> Repo.insert!()

    if must_change_password do
      user
    else
      user |> Ecto.Changeset.change(must_change_password: false) |> Repo.update!()
    end
  end

  def admin_fixture(attrs \\ %{}),
    do: user_fixture(Map.merge(%{role: :admin, must_change_password: false}, Map.new(attrs)))

  def user_scope_fixture(user \\ admin_fixture()), do: Scope.for_user(user)

  def archived_user_fixture(attrs \\ %{}) do
    attrs |> user_fixture() |> User.archive_changeset() |> Repo.update!()
  end
end
