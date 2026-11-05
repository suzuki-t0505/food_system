defmodule FoodVaultWeb.ErrorJSONTest do
  use FoodVaultWeb.ConnCase, async: true

  alias FoodVaultWeb.ErrorJSON

  test "renders 404 in the common error format" do
    assert ErrorJSON.render("404.json", %{}) == %{error: "not_found", message: "見つかりません。"}
  end

  test "renders 400 and 500" do
    assert %{error: "bad_request"} = ErrorJSON.render("400.json", %{})
    assert %{error: "internal_server_error"} = ErrorJSON.render("500.json", %{})
  end

  test "renders unknown statuses with a snake_case code" do
    assert %{error: "bad_gateway", message: "Bad Gateway"} = ErrorJSON.render("502.json", %{})
  end
end
