defmodule FoodVault.SchemaTest do
  use FoodVault.DataCase, async: true

  defmodule Parent do
    use FoodVault.Schema

    schema "schema_test_parents" do
      field :name, :string
      has_many :children, FoodVault.SchemaTest.Child
    end
  end

  defmodule Child do
    use FoodVault.Schema

    schema "schema_test_children" do
      field :name, :string
      belongs_to :parent, FoodVault.SchemaTest.Parent
    end
  end

  setup do
    # 業務テーブルを増やさないため、サンドボックスのトランザクション内に一時テーブルを作る
    Repo.query!("CREATE TEMP TABLE schema_test_parents (id uuid PRIMARY KEY, name text)")

    Repo.query!("""
    CREATE TEMP TABLE schema_test_children (
      id uuid PRIMARY KEY,
      name text,
      parent_id uuid REFERENCES schema_test_parents (id)
    )
    """)

    :ok
  end

  describe "主キーと外部キー" do
    test "ULID (26 文字) が自動採番され、保存・取得できる" do
      parent = Repo.insert!(%Parent{name: "親"})
      child = Repo.insert!(%Child{name: "子", parent_id: parent.id})

      assert byte_size(parent.id) == 26
      assert byte_size(child.id) == 26
      assert Repo.get!(Parent, parent.id).name == "親"
      assert Repo.get!(Child, child.id).parent_id == parent.id
    end

    test "アソシエーションを辿れる" do
      parent = Repo.insert!(%Parent{name: "親"})
      Repo.insert!(%Child{name: "子", parent_id: parent.id})

      assert [%Child{name: "子"}] = Repo.preload(parent, :children).children
    end

    test "DB には 16 バイトで保存される" do
      parent = Repo.insert!(%Parent{name: "親"})
      {:ok, binary} = Ecto.ULID.dump(parent.id)

      assert byte_size(binary) == 16

      assert %{rows: [[^binary]]} =
               Repo.query!("SELECT id FROM schema_test_parents")
    end
  end

  describe "ID の形式検証" do
    test "不正な文字列は cast できない" do
      assert Ecto.ULID.cast("not-a-ulid") == :error
      assert Ecto.ULID.cast("01ARZ3NDEKTSV4RRFFQ69G5FA") == :error
    end

    test "26 文字の ULID は cast できる" do
      ulid = Ecto.ULID.generate()

      assert {:ok, ^ulid} = Ecto.ULID.cast(ulid)
    end

    test "不正な ID での取得は Ecto.Query.CastError になる" do
      assert_raise Ecto.Query.CastError, fn -> Repo.get(Parent, "not-a-ulid") end
    end
  end
end
