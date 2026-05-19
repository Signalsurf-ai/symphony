defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :loopback_only do
    plug(SymphonyElixirWeb.LoopbackOnlyPlug)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :loopback_only])

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    post("/webhooks/linear/agent", SurferWebhookController, :linear_agent)
    post("/webhooks/discord/message", SurferWebhookController, :discord_message)
    post("/webhooks/discord/interactions", SurferWebhookController, :discord_interaction)
    post("/api/v1/surfer/pause", SurferWebhookController, :operator_pause)
    post("/api/v1/surfer/unpause", SurferWebhookController, :operator_unpause)
    get("/api/v1/surfer/runs/:run_id", SurferWebhookController, :operator_run)
    post("/api/v1/surfer/runs/:run_id/cancel", SurferWebhookController, :operator_cancel_run)
    post("/api/v1/surfer/runs/:run_id/retry", SurferWebhookController, :operator_retry_run)
    post("/api/v1/surfer/runs/:run_id/takeover", SurferWebhookController, :operator_takeover_run)
    post("/api/v1/surfer/outbox/requeue", SurferWebhookController, :operator_requeue_pending_writes)
    post("/api/v1/surfer/ledger/backup", SurferWebhookController, :operator_backup_ledger)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:loopback_only)

    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
  end

  scope "/", SymphonyElixirWeb do
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    post("/*path", SurferWebhookController, :platform_webhook)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
