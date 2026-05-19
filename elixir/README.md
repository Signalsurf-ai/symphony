# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Surfer v0.1 VPS Deployment

Surfer is the organization-agent layer built on this runner. Its default trigger path is webhook
first: Linear `AgentSessionEvent` and Discord Interactions enter Surfer directly. The existing
Symphony Linear project poller remains available only as explicit opt-in legacy/fallback behavior
and is disabled in the Surfer workflow example.

### What is implemented

- Linear `AgentSessionEvent` HTTP ingress at `/webhooks/linear/agent` by default, with
  `surfer.platforms.linear.webhook_path` enforced when configured.
- Linear raw-body HMAC verification using `LINEAR_WEBHOOK_SECRET`.
- Linear webhook payload type handling accepts `AgentSessionEvent`; explicit non-agent event
  types return `400` without dispatch.
- Linear `AgentSessionEvent` action handling accepts `created` and `prompted`; unsupported
  actions return `400` without dispatch.
- Linear idempotency keys require real natural-key fields: agent session ID, and either a
  comment/issue ID for `created` or an agent activity ID for `prompted`.
- Surfer v0.1 deployment defaults disable the legacy Symphony Linear project poller with
  `polling.enabled: false`; direct webhook dispatch remains available.
- Enabled Linear, Discord, and GitHub config fails closed at application startup when required
  secrets are missing.
- Early Linear `thought` activity plus final `response` or `error` activity for direct-dispatch runs.
  Failed initial `thought` writes are queued as retryable pending writes while dispatch continues.
  Pre-dispatch Linear error activity failures are queued as retryable pending writes.
- Linear agent-session external URL mutation support, including a Surfer run lookup link when
  `surfer.external_base_url` is configured and pending-write capture if the update fails.
- Linear agent sessions allow one active Surfer run at a time; overlapping events for the same
  session are recorded as `awaiting_input` instead of starting duplicate Codex work.
- Discord HTTP Interactions ingress at `/webhooks/discord/interactions` by default, with
  `surfer.platforms.discord.interactions_path` enforced when configured.
- Discord `PING`/`PONG`, Ed25519 request verification, guild/channel allowlists, `/surfer`
  subcommands, deferred slash-command ACKs, original-response edits, deduplication, and per-user
  cooldowns plus per-channel queued-run limits and optional ledger-backed daily user/channel run
  caps.
- Discord message ingress at `/webhooks/discord/message` for gateway adapters or internal relays,
  with `surfer.platforms.discord.message_ingress_path` and the same configured guild/channel
  allowlists enforced before dispatch.
- Discord idempotency keys require real interaction IDs, or real guild/channel/message IDs for
  message-relay ingress.
- Discord-to-Linear issue creation through Linear `issueCreate`.
- Discord durable `run` requests create a Linear issue and persist the Linear issue link before
  dispatching long-running Codex work.
- Discord original-response edit failures retry within the short-lived interaction-token window
  measured from interaction receipt, emit telemetry after retry exhaustion, and fall back to a bot
  channel message without storing the interaction token.
- Discord Interactions return an immediate paused response without editing the original interaction
  response or dispatching when `surfer.paused: true` or `SURFER_PAUSED=true` is active.
- Discord REST helper errors redact bot-token and interaction-token shaped values before returning
  to callers; completion, fallback, and error notification failures are recorded as retryable
  pending writes without storing interaction tokens.
- Discord lifecycle controls for `cancel` and `retry` against locally-ledgered runs.
- Deterministic repository routing from PRD-shaped `key`/`repo` repository config, explicit
  `repository_key`, Linear team IDs, Discord channel IDs, or a single configured fallback.
  Linear and Discord ingress apply this routing before dispatch; ambiguous routing is recorded as
  `awaiting_input`, and Discord interactions edit the original response with the ambiguous
  repository candidates instead of silently starting work.
- Daily Codex budget-cap enforcement at ingress from the SQLite usage ledger, plus per-run
  budget-cap status marking when recorded run usage reaches the configured cap.
- Optional workspace disk-pressure ingress blocking when `disk_pressure_max_used_percent` is set.
- Workspace retention cleanup helper that preserves active and awaiting-review runs.
- AgentRunner holds an exclusive `.surfer-run.lock` in the workspace while Codex is running.
- Local embedded SQLite run/event/link/idempotency ledger with natural-key atomic claims, status
  transitions, indexes, pending-write events, pending-write requeue result events, budget usage
  events, retry links, bounded transient claim retry, claim-failure 503s before dispatch,
  embedded backup/integrity-check/restore helpers, redacted status error messages, redacted
  event/link external IDs and link URLs, redacted per-run JSONL event logs, loopback-only backup
  creation, and redacted operator lookup data including raw platform payload containers.
- Loopback-only run lookup at `/api/v1/surfer/runs/:run_id`.
- Loopback-only operator pause/unpause plus run controls for cancel, retry, and takeover.
- Loopback-only pending platform-write requeue at `/api/v1/surfer/outbox/requeue`.
- GitHub PR-open ledger bookkeeping records a PR link, `github_pr_opened` event, and
  `awaiting_review` status transition, and updates the Linear agent session with the GitHub PR
  URL when the run has Linear session lineage. Failed PR URL updates are queued as pending writes.
- Minimal Surfer telemetry for run starts/completions/failures/cancellations, duplicates, platform
  write failures/timing, signature failures, Discord follow-up failures, webhook ACK timing, first
  Linear activity timing, Codex run timing, runtime gauges, workspace disk usage, daily budget
  remaining, pending-write backlog/stale age, and budget-cap hits.
- GitHub outbound PR create/update/context helper with redacted review/comment bodies and API
  error payloads, plus scoped Company Brain retrieval that passes provenance-only refs with
  bounded redacted summaries. GitHub webhook ingress is intentionally not implemented for v0.1.
- Shared direct-dispatch claim checks so duplicate Linear issue runners are refused locally.
- Surfer prompt context injection for run ID, request mode, source platform,
  trigger, lineage IDs, routing, read/write constraints, a bounded redacted platform prompt-context
  excerpt, and scoped Company Brain provenance with background authority labeling when retrieved.

Live workspace installation still requires real Linear, Discord, GitHub, and OpenAI/Codex
credentials. The test suite covers deterministic local contracts; it does not fake a successful
live Discord or Linear workspace install.

### How to really host Surfer v0.1

Use Docker Compose on one trusted VPS. Put the public HTTPS reverse proxy in front of only the
webhook paths, keep the operator API loopback-only, and treat Linear as the durable task state. The
SQLite ledger is local operational state for run claims, events, links, pending writes, and lookup.

1. Clone this repository on the VPS and work from `symphony/elixir`.
2. Point DNS and TLS at the VPS. Proxy HTTPS traffic to the loopback-bound container port `4000`
   for `/webhooks/linear/agent`, `/webhooks/discord/interactions`, and, only if you run a gateway
   relay, `/webhooks/discord/message`.
3. Keep `/api/v1/surfer/*` off the public internet. Access it through SSH port forwarding, for
   example `ssh -L 4000:127.0.0.1:4000 surfer@<vps>`.
4. Copy `.env.surfer.example` to `.env.surfer`, fill the real Linear, Discord, GitHub, repository,
   public URL, and mounted Codex home settings, and never commit that file.
5. Create the mounted host paths and make them writable by the container user:

   ```bash
   sudo mkdir -p /srv/surfer/{workspaces,logs,state,codex}
   sudo chown -R 10001:10001 /srv/surfer
   ```

   The default Compose file bind-mounts those paths through `SURFER_HOST_WORKSPACE_ROOT`,
   `SURFER_HOST_LOGS_DIR`, `SURFER_HOST_STATE_DIR`, and `SURFER_HOST_CODEX_HOME`. Inside the
   container they remain `/srv/surfer/workspaces`, `/srv/surfer/logs`, `/srv/surfer/state`, and
   `/home/surfer/.codex`.
6. Build and check the deployment shape. By default Compose binds the service to
   `127.0.0.1:4000`; keep that default unless a firewall/VPN/reverse-proxy layer provides the same
   operator API isolation.

   ```bash
   docker compose -f docker-compose.surfer.yml config
   docker compose -f docker-compose.surfer.yml build
   ```

7. Authenticate the operator-owned OpenAI Pro Codex session into the mounted Codex home:

   ```bash
   docker compose -f docker-compose.surfer.yml run --rm --entrypoint codex surfer login
   ```

8. From the repo checkout, run preflight with the same `.env.surfer` values loaded. Use
   `--skip-codex` only before the OAuth session exists:

   ```bash
   set -a
   . ./.env.surfer
   set +a
   mise exec -- mix surfer.live_preflight
   ```

9. Configure platform ingress:
   - Linear `AgentSessionEvent`: `https://<your-vps-host>/webhooks/linear/agent`.
   - Discord Interactions Endpoint URL:
     `https://<your-vps-host>/webhooks/discord/interactions`.
   - GitHub: outbound token and repository routing only. Do not add GitHub webhooks for Surfer
     v0.1.
10. Start Surfer:

    ```bash
    docker compose -f docker-compose.surfer.yml up -d --build
    curl -fsS http://127.0.0.1:4000/api/v1/state
    ```

11. Smoke one real path from each enabled surface before calling the host ready:
    - Trigger a Linear Agent session and confirm started and final/error agent activities.
    - Run Discord `/surfer ask`, `/surfer issue`, or `/surfer run` from an allowed guild/channel.
    - Confirm repository routing, Codex execution, and GitHub PR creation or update for a durable
      run.
    - Verify operator lookup through the SSH tunnel:
      `curl -fsS http://127.0.0.1:4000/api/v1/surfer/runs/<run_id>`.

Use the pause switch when the host should stop accepting new work:

```bash
curl -X POST http://127.0.0.1:4000/api/v1/surfer/pause
curl -X POST http://127.0.0.1:4000/api/v1/surfer/unpause
```

Run controls are also loopback-only:

```bash
curl -X POST http://127.0.0.1:4000/api/v1/surfer/runs/<run_id>/cancel
curl -X POST http://127.0.0.1:4000/api/v1/surfer/runs/<run_id>/retry
curl -X POST http://127.0.0.1:4000/api/v1/surfer/runs/<run_id>/takeover
curl -X POST http://127.0.0.1:4000/api/v1/surfer/outbox/requeue
curl -X POST http://127.0.0.1:4000/api/v1/surfer/ledger/backup
```

### Docker image

Build the image from the repository root:

```bash
docker build -f elixir/Dockerfile -t surfer:0.1 .
```

Prepare the env file:

```bash
cd elixir
cp .env.surfer.example .env.surfer
```

The Compose file loads committed defaults from `.env.surfer.example` and then overlays optional
local secrets from `.env.surfer`. Keeping `.env.surfer` absent is valid for config/build smoke, but
the service will still fail closed until real platform secrets and mounted paths are configured.

Fill in at minimum:

- `LINEAR_API_KEY`
- `LINEAR_ACCESS_TOKEN`
- `LINEAR_WEBHOOK_SECRET`
- `LINEAR_PROJECT_SLUG`
- `LINEAR_TEAM_ID`
- `DISCORD_PUBLIC_KEY`
- `DISCORD_BOT_TOKEN`
- `DISCORD_APPLICATION_ID` for one-time `/surfer` command registration
- `DISCORD_GUILD_ID`
- `DISCORD_ALLOWED_GUILDS` as a comma-separated ingress allowlist
- `DISCORD_ALLOWED_CHANNELS` as a comma-separated ingress allowlist
- `DISCORD_REPORT_CHANNEL_ID`
- `GITHUB_TOKEN`
- `SURFER_REPOSITORY_URL`
- `SURFER_PUBLIC_URL` when Linear agent sessions should link back to Surfer run lookup
- `SURFER_WORKSPACE_ROOT`
- `SURFER_LOGS_DIR`
- `SURFER_STATE_DIR`
- `SURFER_SQLITE_PATH`
- `SURFER_CODEX_HOME` as the runtime path, usually `/home/surfer/.codex` inside the container

Optional rotation variables:

- `LINEAR_WEBHOOK_SECRET_NEXT`
- `DISCORD_PUBLIC_KEY_NEXT`

Optional host-only Docker variable:

- `SURFER_HOST_BIND` as the host interface for port `4000`, defaulting to `127.0.0.1`
- `SURFER_HOST_CODEX_HOME` as the host path mounted to `/home/surfer/.codex`
- `SURFER_HOST_WORKSPACE_ROOT`, `SURFER_HOST_LOGS_DIR`, and `SURFER_HOST_STATE_DIR` as the host
  paths mounted to the container runtime paths

Before starting live smoke validation, run the checked preflight:

```bash
mise exec -- mix surfer.live_preflight
```

Use `--skip-codex` only for environment and writable mount checks before the Codex OAuth session has
been created. A passing preflight verifies required live-smoke inputs, writable workspace/log/state
and Codex home paths, a writable SQLite ledger parent directory, and the Codex login status command;
it does not replace the Linear, Discord, GitHub, and runner smoke tests.

Authenticate Codex once with the mounted Codex home. This is where the operator-owned OpenAI Pro
OAuth session lives; do not bake it into the image.
Set `surfer.codex.home` to the mounted Codex home, usually `$SURFER_CODEX_HOME`. When
`surfer.codex.auth: openai_pro_oauth` is configured, Surfer runs
`surfer.codex.health_check_command` at startup with `CODEX_HOME` set from `surfer.codex.home`. A
failed health check pauses new dispatch through the runtime pause control instead of silently
sending work into an unauthenticated Codex backend.

```bash
docker compose -f docker-compose.surfer.yml run --rm --entrypoint codex surfer login
```

Start Surfer:

```bash
docker compose -f docker-compose.surfer.yml up -d --build
```

The compose file exposes port `4000` on `127.0.0.1` by default and persists:

- `/srv/surfer/workspaces`
- `/srv/surfer/logs`
- `/srv/surfer/state`
- `/home/surfer/.codex`

The image declares a Docker health check against `http://127.0.0.1:4000/api/v1/state`. It verifies
the local HTTP runtime without calling Linear, Discord, GitHub, or Codex.

### Platform setup

Linear:

1. Create a Linear OAuth application for Surfer.
2. Install it with `actor=app` and scopes that include `read`, `write`, `app:assignable`, and `app:mentionable`.
3. Enable Agent session events.
4. Set the webhook URL to `https://<your-vps-host>/webhooks/linear/agent`, or to the configured
   `surfer.platforms.linear.webhook_path` when overriding the default.
5. Put the webhook secret in `LINEAR_WEBHOOK_SECRET`.
6. During rotation, put the incoming replacement secret in `LINEAR_WEBHOOK_SECRET_NEXT` until Linear has switched over.

Discord:

1. Create a Discord application and bot.
2. Configure the Interactions Endpoint URL as `https://<your-vps-host>/webhooks/discord/interactions`,
   or to the configured `surfer.platforms.discord.interactions_path` when overriding the default.
3. Put the application's public key in `DISCORD_PUBLIC_KEY`.
4. During rotation, put the replacement public key in `DISCORD_PUBLIC_KEY_NEXT` until Discord has switched over.
5. Put the bot token in `DISCORD_BOT_TOKEN`.
6. Register a `/surfer` command using the tested guild upsert helper:

   ```bash
   mise exec -- mix run -e 'IO.inspect(SymphonyElixir.Surfer.Discord.Commands.register_guild_command(%{application_id: System.fetch_env!("DISCORD_APPLICATION_ID"), guild_id: System.fetch_env!("DISCORD_GUILD_ID"), bot_token: System.fetch_env!("DISCORD_BOT_TOKEN")}))'
   ```

   The payload from `SymphonyElixir.Surfer.Discord.Commands.application_command/0` includes
   `ask`, `issue`, `run`, `cancel`, and `retry` subcommands.
   - `ask`, `issue`, and `run` use a string option named `prompt`.
   - `cancel` and `retry` use a string option named `run_id`.
7. Set `DISCORD_GUILD_ID` for command registration and `DISCORD_REPORT_CHANNEL_ID` for the
   default report/routing channel. Set `DISCORD_ALLOWED_GUILDS` and `DISCORD_ALLOWED_CHANNELS`
   to comma-separated allowlists for Discord ingress. If a gateway adapter or internal relay calls
   `/webhooks/discord/message`, keep those allowlists scoped to the same approved Discord surfaces.

GitHub:

1. Provide repository access through the operator environment, usually `GITHUB_TOKEN` and `gh auth`.
2. Configure `surfer.repositories` with `key`, `repo`, `checkout_path`, `default_branch`, and the
   Linear team or Discord channel IDs that should route to that repository.
3. Set `COMPANY_BRAIN_REPO=Signalsurf-ai/signalsurf-company-brain` when
   on-demand Company Brain retrieval should be available.
4. Surfer v0.1 uses GitHub only for outbound repository, PR, and Company Brain context operations;
   do not configure GitHub webhooks as Surfer triggers.

### Runtime contract

Use [`SURFER_WORKFLOW.example.md`](SURFER_WORKFLOW.example.md) as the starting workflow. Secrets must
come from environment variables or a VPS secret manager. SQLite is only a local ledger for run
history, idempotency, and dashboard lookup; Linear remains canonical for durable task state.

Surfer v0.1 should normally keep:

```yaml
polling:
  enabled: false
```

Linear Agent sessions and Discord Interactions are webhook/direct-dispatch paths. When Surfer
Linear or Discord ingress is enabled and `polling.enabled` is omitted, the runtime defaults the
legacy poller to disabled. Enable the legacy poller only by explicitly setting
`polling.enabled: true` as fallback for non-agent Linear project issues, and do not rely on both
trigger paths for the same task queue unless you are intentionally testing migration behavior.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`. For Surfer v0.1 production hosting,
start from `SURFER_WORKFLOW.example.md` or another workflow with `polling.enabled: false`; the
in-repo `WORKFLOW.md` is the legacy Symphony polling workflow.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.
- For Surfer deployments, `surfer.workspace_root` is accepted as an alias for the runtime
  `workspace.root` when `workspace.root` is omitted. If both are set, `workspace.root` remains the
  runner source of truth.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- Surfer runtime pause and unpause are available as loopback-only `POST /api/v1/surfer/pause` and
  `POST /api/v1/surfer/unpause`. Runtime unpause clears only the operator override; if
  `surfer.paused: true` or `SURFER_PAUSED=true` is configured, ingress remains paused.
  `SURFER_PAUSED=false` does not unpause a workflow configured with `surfer.paused: true`; remove
  the configured pause to resume ingress.
  `SURFER_PAUSE_MODE=cancel` cancels active direct-dispatch runs when the operator pause endpoint is
  used; the default `drain` mode lets active runs continue while blocking new dispatch. Unsupported
  `SURFER_PAUSE_MODE` values fail config validation before the service starts.
- Surfer run lookup is available at `/api/v1/surfer/runs/:run_id` only from loopback addresses.
  It returns the redacted ledger run, events, links, latest error, and run-scoped log tail; prompt
  bodies, tokens, and raw platform payload containers are hidden. When `surfer.storage.logs_dir` is
  configured, the log tail comes from `<logs_dir>/<run_id>.jsonl`.
- Surfer operator controls are available as loopback-only `POST` endpoints:
  `/api/v1/surfer/runs/:run_id/cancel`, `/api/v1/surfer/runs/:run_id/retry`, and
  `/api/v1/surfer/runs/:run_id/takeover`.
- Surfer pending-write requeue is available as `POST /api/v1/surfer/outbox/requeue` only from
  loopback addresses. It retries supported Linear and Discord channel-message writes and records
  drained or failed outcomes. Listing pending writes emits `pending_write_backlog` telemetry and
  `pending_write_stale` when the oldest pending write is at least 10 minutes old.
- Surfer ledger backup creation is available as `POST /api/v1/surfer/ledger/backup` only from
  loopback addresses. Backups are written under the ledger state directory's `backups/` folder and
  verified with SQLite integrity checks before the response is returned.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
