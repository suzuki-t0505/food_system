defmodule FoodShipWeb.PageController do
  use FoodShipWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
