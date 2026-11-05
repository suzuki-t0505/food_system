defmodule FoodShipWeb.Router do
  use FoodShipWeb, :router

  import FoodShipWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FoodShipWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", FoodShipWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:food_ship, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FoodShipWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## 認証系(ログイン不要)

  scope "/", FoodShipWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{FoodShipWeb.UserAuth, :mount_current_scope}] do
      live "/users/log_in", UserSessionLive.Login, :new
    end

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
  end

  ## パスワード変更(ログイン済み。must_change_password の強制遷移の対象外)

  scope "/", FoodShipWeb do
    pipe_through [:browser, :require_logged_in_user]

    live_session :password_change,
      on_mount: [{FoodShipWeb.UserAuth, :ensure_authenticated_for_password_change}] do
      live "/users/password", UserSessionLive.Password, :edit
    end

    post "/users/update_password", UserSessionController, :update_password
  end

  ## 全ロール(ログイン済み)

  scope "/", FoodShipWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    live_session :require_authenticated_user,
      on_mount: [{FoodShipWeb.UserAuth, :ensure_authenticated}] do
      live "/masters/clients", ClientLive.Index, :index
      live "/masters/shipping_items", ShippingItemLive.Index, :index
      live "/masters/expiration_rules", ExpirationRuleLive.Index, :index
    end
  end

  ## admin 専用

  scope "/management", FoodShipWeb.Management do
    pipe_through [:browser, :require_authenticated_admin_user]

    live_session :require_authenticated_admin_user,
      on_mount: [{FoodShipWeb.UserAuth, :ensure_authenticated_admin}] do
      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Form, :new
      live "/users/:id/reset_password", UserLive.Form, :reset_password

      live "/clients/new", ClientLive.Form, :new
      live "/clients/:id/edit", ClientLive.Form, :edit
      live "/shipping_items/new", ShippingItemLive.Form, :new
      live "/shipping_items/:id/edit", ShippingItemLive.Form, :edit
      live "/expiration_rules/new", ExpirationRuleLive.Form, :new
      live "/expiration_rules/:id/edit", ExpirationRuleLive.Form, :edit
    end
  end
end
