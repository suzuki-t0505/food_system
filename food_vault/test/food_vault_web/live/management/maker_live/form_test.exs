defmodule FoodVaultWeb.Management.MakerLive.FormTest do
  use FoodVaultWeb.ConnCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.MastersFixtures
  import Phoenix.LiveViewTest

  alias FoodVault.Makers

  describe "アクセス制御" do
    test "未ログインはログイン画面へ", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, ~p"/management/makers/new")
    end

    for role <- [:staff, :viewer] do
      test "#{role} は入れない", %{conn: conn} do
        user = user_fixture(%{role: unquote(role), must_change_password: false})

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "権限がありません。"}}}} =
                 conn |> log_in_user(user) |> live(~p"/management/makers/new")
      end
    end
  end

  describe "admin" do
    @describetag role: :admin
    setup :register_and_log_in_user

    test "登録できる", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/makers/new")

      lv
      |> form("#maker-form", maker: %{maker_code: "MK01", maker_name: "新メーカー"})
      |> render_submit()

      assert_redirect(lv, ~p"/masters/makers")
      assert Enum.any?(Makers.all_makers(), &(&1.maker_code == "MK01"))
    end

    test "必須項目が空ならエラーを表示して保存しない", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/management/makers/new")

      html =
        lv |> form("#maker-form", maker: %{maker_code: "", maker_name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "コードの重複はエラー", %{conn: conn} do
      existing = maker_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/makers/new")

      html =
        lv
        |> form("#maker-form", maker: %{maker_code: existing.maker_code, maker_name: "重複"})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "編集できる", %{conn: conn} do
      maker = maker_fixture()
      {:ok, lv, _} = live(conn, ~p"/management/makers/#{maker.id}/edit")

      lv |> form("#maker-form", maker: %{maker_name: "改名"}) |> render_submit()
      assert_redirect(lv, ~p"/masters/makers")
      assert Makers.get_maker!(maker.id).maker_name == "改名"
    end
  end
end
