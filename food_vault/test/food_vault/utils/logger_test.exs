defmodule FoodVault.Utils.LoggerTest do
  use FoodVault.DataCase, async: false
  use FoodVault.Utils.Logger

  import ExUnit.CaptureLog

  alias FoodVault.Utils.Logger, as: AppLogger
  alias FoodVault.LoggerTestSchemas.{Account, Post}

  describe "カテゴリ付きのログ" do
    test "定義済みのカテゴリでメッセージとカテゴリ名が出力される" do
      log = capture_log(fn -> Logger.warning("入荷を登録しました。", :create, %{id: 1}) end)

      assert log =~ "入荷を登録しました。"
      assert log =~ "作成"
    end

    test "error レベルでも出力される" do
      log = capture_log(fn -> Logger.error("API が失敗しました。", :api, %{status: 500}) end)

      assert log =~ "API が失敗しました。"
    end

    test "変数のパスワードは出力されない" do
      log =
        capture_log(fn ->
          Logger.warning("ログインしました。", :log_in, %{email: "a@example.com", password: "secret-pw"})
        end)

      assert log =~ "a@example.com"
      refute log =~ "secret-pw"
    end
  end

  describe "未定義のカテゴリ" do
    test "raise_on_unknown_category が true なら ArgumentError" do
      assert_raise ArgumentError, ~r/:no_such_category/, fn ->
        Logger.warning("x", :no_such_category, %{})
      end
    end

    test "false ならカテゴリ名をそのまま出力して落ちない" do
      put_raise_on_unknown_category(false)

      log = capture_log(fn -> Logger.warning("x", :no_such_category, %{}) end)

      assert log =~ ":no_such_category"
    end
  end

  describe "normalize/1" do
    test "マップの機微キー (atom・文字列) を除く" do
      assert AppLogger.normalize(%{"password" => "a", token: "b", name: "c"}) == %{name: "c"}
    end

    test "キーワードリストの機微キーを除く" do
      assert AppLogger.normalize(password: "a", name: "c") == [name: "c"]
    end

    test "ネストしたマップ・リストも再帰して除く" do
      input = %{user: %{password: "a", name: "c"}, list: [%{token: "t", id: 1}]}

      assert AppLogger.normalize(input) == %{user: %{name: "c"}, list: [%{id: 1}]}
    end

    test "スキーマは __meta__・redact: true・仮想フィールドを除く" do
      account = %Account{
        id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        email: "a@example.com",
        password: "pw",
        hashed_password: "hash",
        memo: "仮想"
      }

      result = AppLogger.normalize(account)

      assert result.email == "a@example.com"
      refute Map.has_key?(result, :__meta__)
      refute Map.has_key?(result, :password)
      refute Map.has_key?(result, :hashed_password)
      refute Map.has_key?(result, :memo)
    end

    test "未ロードのアソシエーションを除く" do
      result = AppLogger.normalize(%Account{email: "a@example.com"})

      refute Map.has_key?(result, :posts)
    end

    test "ロード済みのアソシエーションは再帰して整形する" do
      account = %Account{posts: [%Post{title: "t"}]}

      assert [%{title: "t"} = post] = AppLogger.normalize(account).posts
      refute Map.has_key?(post, :__meta__)
    end

    test "changeset の changes から redact フィールドを除く" do
      changeset =
        Ecto.Changeset.cast(%Account{}, %{email: "a@example.com", password: "pw"}, [
          :email,
          :password
        ])

      result = AppLogger.normalize(changeset)

      assert result.changes == %{email: "a@example.com"}
      refute inspect(result) =~ "pw"
    end

    test "日時などの構造体はそのまま返す" do
      now = DateTime.utc_now()

      assert AppLogger.normalize(%{at: now}) == %{at: now}
    end
  end

  defp put_raise_on_unknown_category(value) do
    original = Application.get_env(:food_vault, AppLogger)
    Application.put_env(:food_vault, AppLogger, raise_on_unknown_category: value)
    on_exit(fn -> Application.put_env(:food_vault, AppLogger, original) end)
  end
end
