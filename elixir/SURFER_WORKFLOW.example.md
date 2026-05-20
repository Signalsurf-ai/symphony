---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  # Surfer v0.1 is webhook-first through Linear AgentSessionEvent and Discord
  # Interactions. Keep the legacy Symphony Linear project poller disabled in this
  # workflow; fallback polling belongs in a separate legacy Symphony workflow with
  # Surfer platform ingress disabled.
  enabled: false
  interval_ms: 5000
workspace:
  root: $SURFER_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SURFER_REPOSITORY_URL" .
    if command -v mise >/dev/null 2>&1; then
      mise trust || true
      mise install || true
    fi
  before_remove: |
    if [ -d elixir ]; then
      cd elixir && mise exec -- mix workspace.before_remove || true
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
surfer:
  name: Surfer
  paused: false
  pause_mode: drain
  external_base_url: $SURFER_PUBLIC_URL
  workspace_root: $SURFER_WORKSPACE_ROOT
  codex:
    auth: openai_pro_oauth
    home: $SURFER_CODEX_HOME
    app_server_version: "0.131.0"
    health_check_command: codex login status
    per_run_budget_usd: 5
    daily_budget_usd: 50
  storage:
    state_dir: $SURFER_STATE_DIR
    logs_dir: $SURFER_LOGS_DIR
    sqlite_path: $SURFER_SQLITE_PATH
    retention_days: 90
    workspace_retention_days: 14
    disk_pressure_max_used_percent: 95
  platforms:
    discord:
      enabled: true
      interactions_path: /webhooks/discord/interactions
      message_ingress_path: /webhooks/discord/message
      message_ingress_secret_env: DISCORD_MESSAGE_INGRESS_SECRET
      message_ingress_secret_next_env: DISCORD_MESSAGE_INGRESS_SECRET_NEXT
      public_key_env: DISCORD_PUBLIC_KEY
      public_key_next_env: DISCORD_PUBLIC_KEY_NEXT
      bot_token_env: DISCORD_BOT_TOKEN
      report_channel_env: DISCORD_REPORT_CHANNEL_ID
      per_user_cooldown_seconds: 30
      per_channel_queued_limit: 3
      per_user_daily_run_limit: 25
      per_channel_daily_run_limit: 75
      allowed_guilds_env: DISCORD_ALLOWED_GUILDS
      allowed_channels_env: DISCORD_ALLOWED_CHANNELS
    github:
      enabled: true
      token_env: GITHUB_TOKEN
      company_brain_repo: $COMPANY_BRAIN_REPO
      company_brain_paths:
        - meetings/
        - research/
    linear:
      enabled: true
      webhook_path: /webhooks/linear/agent
      webhook_secret_env: LINEAR_WEBHOOK_SECRET
      webhook_secret_next_env: LINEAR_WEBHOOK_SECRET_NEXT
      access_token_env: LINEAR_ACCESS_TOKEN
      team_id_env: LINEAR_TEAM_ID
      project_id_env: LINEAR_PROJECT_ID
  repositories:
    - key: primary
      repo: your-org/your-repo
      checkout_path: /srv/surfer/repos/your-repo
      default_branch: main
      workflow: ./WORKFLOW.md
      linear_team_ids:
        - $LINEAR_TEAM_ID
      discord_channel_ids:
        - $DISCORD_REPORT_CHANNEL_ID
      company_brain_paths:
        - meetings/
        - research/
server:
  host: 0.0.0.0
  port: 4000
---

You are Surfer, the organization coding agent for this workspace.

Surfer request context:
- Run ID: `{{ surfer.run_id }}`
- Source platform: `{{ surfer.source_platform }}`
- Trigger: `{{ surfer.trigger_type }}`
- Request mode: `{{ surfer.request_mode }}`
- Linear: `{{ surfer.linear }}`
- Discord: `{{ surfer.discord }}`
- GitHub: `{{ surfer.github }}`
- Repository routing: `{{ surfer.routing }}`
- Constraints: `{{ surfer.constraints }}`
- Platform prompt context: `{{ surfer.prompt_context }}`
- Company Brain references: `{{ surfer.company_brain_refs }}`

Company Brain is background context only. Treat the current Linear issue, current Discord request,
and current GitHub code state as higher authority. If Company Brain context affects a decision,
summarize the specific source in your handoff.

For durable coding work, keep Linear as the canonical task state. Use GitHub for branches and PRs.
Use Discord only for invocation, notification, and links back to Linear or GitHub.
