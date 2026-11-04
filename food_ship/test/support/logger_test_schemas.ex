defmodule FoodShip.LoggerTestSchemas do
  @moduledoc "Logger.normalize/1 のテスト用スキーマ (テーブルは作らない)。"

  defmodule Account do
    @moduledoc false
    use FoodShip.Schema

    schema "log_test_accounts" do
      field :email, :string
      field :password, :string, virtual: true, redact: true
      field :hashed_password, :string, redact: true
      field :memo, :string, virtual: true
      has_many :posts, FoodShip.LoggerTestSchemas.Post
    end
  end

  defmodule Post do
    @moduledoc false
    use FoodShip.Schema

    schema "log_test_posts" do
      field :title, :string
      belongs_to :account, FoodShip.LoggerTestSchemas.Account
    end
  end
end
