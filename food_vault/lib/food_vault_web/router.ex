defmodule FoodVaultWeb.Router do
  use FoodVaultWeb, :router

  import FoodVaultWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FoodVaultWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", FoodVaultWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:food_vault, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FoodVaultWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## 認証系(ログイン不要)

  scope "/", FoodVaultWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{FoodVaultWeb.UserAuth, :mount_current_scope}] do
      live "/users/log_in", UserSessionLive.Login, :new
    end

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
  end

  ## パスワード変更(ログイン済み。must_change_password の強制遷移の対象外)

  scope "/", FoodVaultWeb do
    pipe_through [:browser, :require_logged_in_user]

    live_session :password_change,
      on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated_for_password_change}] do
      live "/users/password", UserSessionLive.Password, :edit
    end

    post "/users/update_password", UserSessionController, :update_password
  end

  ## 全ロール(ログイン済み)

  scope "/", FoodVaultWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    live_session :require_authenticated_user,
      on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated}] do
      live "/inventory_lots", InventoryLotLive.Index, :index
      live "/inventory_lots/:id", InventoryLotLive.Show, :show
      live "/inventory_transactions", InventoryTransactionLive.Index, :index

      live "/masters/makers", MakerLive.Index, :index
      live "/masters/warehouses", WarehouseLive.Index, :index
      live "/masters/items", ItemLive.Index, :index
    end
  end

  ## staff 以上

  scope "/", FoodVaultWeb do
    pipe_through [:browser, :require_authenticated_staff_user]

    live_session :require_authenticated_staff,
      on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated_staff}] do
      live "/inventory_receipts/new", InventoryReceiptLive.Form, :new
    end
  end

  ## admin 専用

  scope "/management", FoodVaultWeb.Management do
    pipe_through [:browser, :require_authenticated_admin_user]

    live_session :require_authenticated_admin_user,
      on_mount: [{FoodVaultWeb.UserAuth, :ensure_authenticated_admin}] do
      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Form, :new
      live "/users/:id/reset_password", UserLive.Form, :reset_password

      live "/makers/new", MakerLive.Form, :new
      live "/makers/:id/edit", MakerLive.Form, :edit
      live "/warehouses/new", WarehouseLive.Form, :new
      live "/warehouses/:id/edit", WarehouseLive.Form, :edit
      live "/items/new", ItemLive.Form, :new
      live "/items/:id/edit", ItemLive.Form, :edit
    end
  end
end
