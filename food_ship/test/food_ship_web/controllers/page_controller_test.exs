defmodule FoodShipWeb.PageControllerTest do
  use FoodShipWeb.ConnCase

  test "未ログインはログイン画面へ遷移する", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log_in"
  end

  describe "ログイン済み" do
    setup :register_and_log_in_user

    test "GET / は 200 でユーザー名を表示する", %{conn: conn, user: user} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ user.name
    end
  end
end
