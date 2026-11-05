defmodule FoodShipWeb.PageController do
  use FoodShipWeb, :controller

  @doc "`/` は作業画面へ。ホーム画面は持たない。"
  def home(conn, _params) do
    redirect(conn, to: ~p"/shipping_slips")
  end
end
