defmodule FoodVault.Utils.OperationLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias FoodVault.Utils.OperationLog
  alias Phoenix.LiveView.Socket

  defp socket(assigns \\ %{}) do
    %Socket{view: FoodVaultWeb.ItemLive.Index, assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  # 操作ログは info レベル。テスト環境の warning では出力されないため、一時的に下げる
  setup do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  describe "info/4" do
    test "LiveView: 操作者・ページ・データ・カテゴリを出力する" do
      socket = socket(%{current_scope: %{user: %{id: "USER01"}}, live_action: :new})

      log =
        capture_log(fn ->
          OperationLog.info(socket, "品目を登録しました。", :create, %{id: "ITEM01", name: "米"})
        end)

      assert log =~ "品目を登録しました。"
      assert log =~ "作成"
      assert log =~ "USER01"
      assert log =~ "FoodVaultWeb.ItemLive.Index (new)"
      assert log =~ "ITEM01"
    end

    test "Controller: リクエストパスを出力する" do
      conn = conn(:post, "/items")

      log = capture_log(fn -> OperationLog.info(conn, "品目を更新しました。", :update, %{id: 1}) end)

      assert log =~ "/items"
      assert log =~ "更新"
    end

    test "認証前 (current_scope なし) でも落ちない" do
      log = capture_log(fn -> OperationLog.info(socket(), "削除しました。", :delete, %{id: 1}) end)

      assert log =~ "削除しました。"
    end

    test "データの機微情報は出力しない" do
      log =
        capture_log(fn ->
          OperationLog.info(socket(), "ユーザーを更新しました。", :update, %{id: 1, password: "secret-pw"})
        end)

      refute log =~ "secret-pw"
    end

    test "create / update / delete 以外のカテゴリは受け付けない" do
      assert_raise FunctionClauseError, fn ->
        apply(OperationLog, :info, [socket(), "x", :log_in, %{}])
      end
    end
  end
end
