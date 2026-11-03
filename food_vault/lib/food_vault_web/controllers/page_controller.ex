defmodule FoodVaultWeb.PageController do
  use FoodVaultWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
