defmodule FoodVault.Schema do
  @moduledoc """
  全スキーマが `use` する共通マクロ。`use Ecto.Schema` は直書きしない。

  主キーと外部キーは ULID (`Ecto.ULID`)。DB の列は `:binary_id` (uuid 型) で保存される。
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.ULID, autogenerate: true}
      @foreign_key_type Ecto.ULID
    end
  end
end
