defmodule FoodVault.LoggerTestSchemas do
  @moduledoc "Logger.normalize/1 のテスト用スキーマ (テーブルは作らない)。"

  defmodule Account do
    @moduledoc false
    use FoodVault.Schema

    schema "log_test_accounts" do
      field :email, :string
      field :password, :string, virtual: true, redact: true
      field :hashed_password, :string, redact: true
      field :memo, :string, virtual: true
      has_many :posts, FoodVault.LoggerTestSchemas.Post
    end
  end

  defmodule Post do
    @moduledoc false
    use FoodVault.Schema

    schema "log_test_posts" do
      field :title, :string
      belongs_to :account, FoodVault.LoggerTestSchemas.Account
    end
  end
end
