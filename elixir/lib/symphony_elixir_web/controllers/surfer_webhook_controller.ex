defmodule SymphonyElixirWeb.SurferWebhookController do
  @moduledoc """
  HTTP ingress for Surfer platform events.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Linear.Issue

  alias SymphonyElixir.Surfer.{
    Budget,
    Discord,
    Lifecycle,
    Metrics,
    Operator,
    RunLedger,
    RunRequest,
    SecretRedactor,
    WorkspaceLifecycle
  }

  alias SymphonyElixir.Surfer.Linear.{IssueCreator, Session, Webhook}

  @claim_retry_delays_ms [10, 25]
  @default_linear_webhook_path "/webhooks/linear/agent"
  @default_discord_message_path "/webhooks/discord/message"
  @default_discord_interactions_path "/webhooks/discord/interactions"
  @task_ledger_path_key {__MODULE__, :surfer_ledger_path}
  @discord_interaction_retry_deadline_key "__surfer_interaction_retry_deadline_ms"
  @discord_interaction_response_retry_backoff_ms 1_000
  @discord_interaction_token_window_ms 15 * 60 * 1_000

  @spec platform_webhook(Conn.t(), map()) :: Conn.t()
  def platform_webhook(conn, params) do
    settings = Config.settings!()
    linear_path = configured_path(settings.surfer.platforms.linear.webhook_path, @default_linear_webhook_path)
    discord_message_path = configured_path(settings.surfer.platforms.discord.message_ingress_path, @default_discord_message_path)

    discord_interactions_path =
      configured_path(settings.surfer.platforms.discord.interactions_path, @default_discord_interactions_path)

    case conn.request_path do
      ^linear_path -> linear_agent(conn, params)
      ^discord_message_path -> discord_message(conn, params)
      ^discord_interactions_path -> discord_interaction(conn, params)
      _path -> not_found_response(conn)
    end
  end

  @spec linear_agent(Conn.t(), map()) :: Conn.t()
  def linear_agent(conn, params) do
    started_at = System.monotonic_time(:millisecond)
    signature = conn |> get_req_header("linear-signature") |> List.first()
    linear = Config.settings!().surfer.platforms.linear
    path = configured_path(linear.webhook_path, @default_linear_webhook_path)
    secrets = linear_webhook_secret_slots(linear)

    response_conn =
      with :ok <- require_configured_path(conn, path),
           :ok <- require_platform_enabled(linear.enabled),
           :ok <- require_secret(linear.enabled, secrets, :missing_linear_webhook_secret),
           {:ok, raw_body} <- require_raw_body(conn),
           :ok <- Webhook.verify(raw_body, signature, secrets),
           {:ok, request} <- RunRequest.from_linear_agent_session_event(params),
           :ok <- require_secret(linear.enabled, linear.access_token, :missing_linear_access_token),
           {:ok, response} <- claim_run(request, :linear),
           {:ok, response} <- maybe_dispatch_linear(response, request) do
        json(conn |> put_status(202), response)
      else
        {:error, :unconfigured_webhook_path} ->
          not_found_response(conn)

        {:error, :platform_disabled} ->
          not_found_response(conn)

        {:error, :missing_linear_webhook_secret} ->
          error_response(conn, 503, "missing_linear_webhook_secret", "Linear webhook secret is required when Linear ingress is enabled")

        {:error, :missing_secret} ->
          error_response(conn, 503, "missing_linear_webhook_secret", "Linear webhook secret is required when Linear ingress is enabled")

        {:error, :missing_linear_access_token} ->
          error_response(conn, 503, "missing_linear_access_token", "Linear access token is required when Linear ingress is enabled")

        {:error, :missing_raw_body} ->
          error_response(conn, 400, "missing_raw_body", "Raw request body is required for webhook signature verification")

        {:error, :missing_signature} ->
          record_signature_failure(:linear, :missing_signature)
          error_response(conn, 401, "missing_signature", "Linear signature is required")

        {:error, :invalid_signature} ->
          record_signature_failure(:linear, :invalid_signature)
          error_response(conn, 401, "invalid_signature", "Linear signature is invalid")

        {:error, :stale_timestamp} ->
          record_signature_failure(:linear, :stale_timestamp)
          error_response(conn, 401, "stale_timestamp", "Linear webhook timestamp is stale")

        {:error, :invalid_timestamp} ->
          record_signature_failure(:linear, :invalid_timestamp)
          error_response(conn, 401, "invalid_timestamp", "Linear webhook timestamp is invalid")

        {:error, {:ledger_claim_failed, reason}} ->
          error_response(conn, 503, "ledger_claim_failed", "Surfer run ledger claim failed: #{safe_inspect(reason)}")

        {:error, {:unsupported_linear_agent_action, action}} ->
          error_response(conn, 400, "unsupported_linear_agent_action", "Unsupported Linear agent session action: #{safe_inspect(action)}")

        {:error, :missing_linear_agent_action} ->
          error_response(conn, 400, "missing_linear_agent_action", "Linear agent session action is required")

        {:error, {:unsupported_linear_event_type, type}} ->
          error_response(conn, 400, "unsupported_linear_event_type", "Unsupported Linear event type: #{safe_inspect(type)}")

        {:error, :missing_linear_event_type} ->
          error_response(conn, 400, "missing_linear_event_type", "Linear event type is required")

        {:error, :missing_linear_agent_session_id} ->
          error_response(conn, 400, "missing_linear_agent_session_id", "Linear agent session id is required")

        {:error, :missing_linear_agent_activity_id} ->
          error_response(conn, 400, "missing_linear_agent_activity_id", "Linear prompted agent activity id is required")

        {:error, :missing_linear_prompted_directive} ->
          error_response(conn, 400, "missing_linear_prompted_directive", "Linear prompted agent directive text is required")

        {:error, :missing_linear_issue_or_comment_id} ->
          error_response(conn, 400, "missing_linear_issue_or_comment_id", "Linear issue id or comment id is required")

        {:error, reason} ->
          error_response(conn, 500, "surfer_dispatch_failed", safe_inspect(reason))
      end

    emit_webhook_ack(:linear, path, started_at, response_conn)
    response_conn
  end

  @spec discord_message(Conn.t(), map()) :: Conn.t()
  def discord_message(conn, params) do
    started_at = System.monotonic_time(:millisecond)
    discord = Config.settings!().surfer.platforms.discord
    path = configured_path(discord.message_ingress_path, @default_discord_message_path)
    signature = conn |> get_req_header("x-surfer-discord-relay-signature") |> List.first()
    timestamp = conn |> get_req_header("x-surfer-discord-relay-timestamp") |> List.first()
    secrets = discord_message_ingress_secret_slots(discord)
    signature_opts = [max_age_seconds: discord.signature_max_age_seconds]

    response_conn =
      with :ok <- require_configured_path(conn, path),
           :ok <- require_platform_enabled(discord.enabled),
           :ok <- require_secret(discord.enabled, secrets, :missing_discord_message_ingress_secret),
           {:ok, raw_body} <- require_raw_body(conn),
           :ok <-
             Discord.Ingress.verify_message_signature(raw_body, signature, timestamp, secrets, signature_opts),
           {:ok, request} <-
             Discord.Ingress.normalize_message(params,
               allowed_guilds: discord.allowed_guilds,
               allowed_channels: discord.allowed_channels
             ),
           :ok <- require_secret(discord.enabled, discord.bot_token, :missing_discord_bot_token) do
        with {:ok, response} <- claim_run(request, :discord),
             :ok <- maybe_dispatch_discord(response, request, params, discord) do
          response =
            response
            |> Map.put(:mode, to_string(request.request.mode))

          conn
          |> put_status(202)
          |> json(response)
        else
          {:error, :rate_limited} ->
            error_response(conn, 429, "rate_limited", "Discord rate limit exceeded")

          {:error, {:ledger_claim_failed, reason}} ->
            error_response(conn, 503, "ledger_claim_failed", "Surfer run ledger claim failed: #{safe_inspect(reason)}")

          {:error, reason} ->
            error_response(conn, 500, "surfer_dispatch_failed", safe_inspect(reason))
        end
      else
        {:error, :unconfigured_webhook_path} ->
          not_found_response(conn)

        {:error, :platform_disabled} ->
          not_found_response(conn)

        {:error, :missing_discord_message_ingress_secret} ->
          error_response(conn, 503, "missing_discord_message_ingress_secret", "Discord message relay secret is required when message ingress is enabled")

        {:error, :missing_secret} ->
          error_response(conn, 503, "missing_discord_message_ingress_secret", "Discord message relay secret is required when message ingress is enabled")

        {:error, :missing_raw_body} ->
          error_response(conn, 400, "missing_raw_body", "Raw request body is required for Discord message relay signature verification")

        {:error, :missing_discord_bot_token} ->
          error_response(conn, 503, "missing_discord_bot_token", "Discord bot token is required when Discord ingress is enabled")

        {:error, :missing_signature} ->
          record_signature_failure(:discord_message, :missing_signature)
          error_response(conn, 401, "missing_discord_message_relay_signature", "Discord message relay signature is required")

        {:error, :missing_timestamp} ->
          record_signature_failure(:discord_message, :missing_timestamp)
          error_response(conn, 401, "missing_discord_message_relay_timestamp", "Discord message relay timestamp is required")

        {:error, :invalid_signature} ->
          record_signature_failure(:discord_message, :invalid_signature)
          error_response(conn, 401, "invalid_discord_message_relay_signature", "Discord message relay signature is invalid")

        {:error, :stale_timestamp} ->
          record_signature_failure(:discord_message, :stale_timestamp)
          error_response(conn, 401, "stale_discord_message_relay_timestamp", "Discord message relay timestamp is stale")

        {:error, :invalid_timestamp} ->
          record_signature_failure(:discord_message, :invalid_timestamp)
          error_response(conn, 401, "invalid_discord_message_relay_timestamp", "Discord message relay timestamp is invalid")

        {:error, {:unauthorized_guild, _guild_id}} ->
          error_response(conn, 403, "unauthorized_guild", "Discord guild is not allowed")

        {:error, {:unauthorized_channel, _channel_id}} ->
          error_response(conn, 403, "unauthorized_channel", "Discord channel is not allowed")

        {:error, :missing_discord_message_id} ->
          error_response(conn, 400, "missing_discord_message_id", "Discord message id is required")

        {:error, :missing_discord_guild_id} ->
          error_response(conn, 400, "missing_discord_guild_id", "Discord guild id is required")

        {:error, :missing_discord_channel_id} ->
          error_response(conn, 400, "missing_discord_channel_id", "Discord channel id is required")
      end

    emit_webhook_ack(:discord, path, started_at, response_conn)
    response_conn
  end

  @spec discord_interaction(Conn.t(), map()) :: Conn.t()
  def discord_interaction(conn, params) do
    started_at = System.monotonic_time(:millisecond)
    discord = Config.settings!().surfer.platforms.discord
    path = configured_path(discord.interactions_path, @default_discord_interactions_path)
    signature = conn |> get_req_header("x-signature-ed25519") |> List.first()
    timestamp = conn |> get_req_header("x-signature-timestamp") |> List.first()
    public_keys = discord_public_key_slots(discord)

    response_conn =
      with :ok <- require_configured_path(conn, path),
           :ok <- require_platform_enabled(discord.enabled),
           :ok <- require_secret(discord.enabled, public_keys, :missing_discord_public_key),
           {:ok, raw_body} <- require_raw_body(conn) do
        verify_discord_interaction(conn, params, raw_body, signature, timestamp, discord, public_keys, started_at)
      else
        {:error, :unconfigured_webhook_path} ->
          not_found_response(conn)

        {:error, :platform_disabled} ->
          not_found_response(conn)

        {:error, :missing_discord_public_key} ->
          error_response(conn, 503, "missing_discord_public_key", "Discord public key is required when Discord ingress is enabled")

        {:error, :missing_raw_body} ->
          error_response(conn, 400, "missing_raw_body", "Raw request body is required for webhook signature verification")
      end

    emit_webhook_ack(:discord, path, started_at, response_conn)
    response_conn
  end

  @spec operator_run(Conn.t(), map()) :: Conn.t()
  def operator_run(conn, %{"run_id" => run_id}) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         {:ok, lookup} <- Operator.lookup_run(db_path, run_id) do
      json(conn, lookup)
    else
      {:error, :forbidden} ->
        error_response(conn, 403, "operator_lookup_forbidden", "Surfer run lookup is loopback-only")

      {:error, :disabled} ->
        error_response(conn, 404, "surfer_ledger_disabled", "Surfer run ledger is not configured")

      {:error, :not_found} ->
        error_response(conn, 404, "surfer_run_not_found", "Surfer run was not found")

      {:error, reason} ->
        error_response(conn, 500, "surfer_lookup_failed", safe_inspect(reason))
    end
  end

  @spec operator_pause(Conn.t(), map()) :: Conn.t()
  def operator_pause(conn, params) do
    case require_loopback(conn) do
      :ok ->
        settings = Config.settings!()

        json(
          conn,
          Operator.pause(
            actor: "operator:http",
            reason: Map.get(params, "reason"),
            configured_paused: settings.surfer.paused,
            pause_mode: settings.surfer.pause_mode
          )
        )

      error ->
        operator_control_error(conn, error)
    end
  end

  @spec operator_unpause(Conn.t(), map()) :: Conn.t()
  def operator_unpause(conn, _params) do
    case require_loopback(conn) do
      :ok ->
        json(conn, Operator.unpause(actor: "operator:http", configured_paused: configured_surfer_paused?()))

      error ->
        operator_control_error(conn, error)
    end
  end

  @spec operator_cancel_run(Conn.t(), map()) :: Conn.t()
  def operator_cancel_run(conn, %{"run_id" => run_id}) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         :ok <- Lifecycle.cancel(db_path, run_id, actor: "operator:http", reason: "cancelled by operator"),
         :ok <- cancel_active_run(run_id, actor: "operator:http", reason: "cancelled by operator") do
      json(conn, %{run_id: run_id, status: "cancelled"})
    else
      error -> operator_control_error(conn, error)
    end
  end

  @spec operator_retry_run(Conn.t(), map()) :: Conn.t()
  def operator_retry_run(conn, %{"run_id" => run_id} = params) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         {:ok, retry} <- Lifecycle.retry(db_path, run_id, operator_retry_opts(params)) do
      json(conn, retry)
    else
      error -> operator_control_error(conn, error)
    end
  end

  @spec operator_takeover_run(Conn.t(), map()) :: Conn.t()
  def operator_takeover_run(conn, %{"run_id" => run_id}) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         :ok <- Lifecycle.takeover(db_path, run_id, actor: "operator:http", reason: "taken over by operator"),
         :ok <- stop_active_run_for_takeover(run_id, actor: "operator:http", reason: "taken over by operator") do
      json(conn, %{run_id: run_id, status: "awaiting_review"})
    else
      error -> operator_control_error(conn, error)
    end
  end

  @spec operator_requeue_pending_writes(Conn.t(), map()) :: Conn.t()
  def operator_requeue_pending_writes(conn, _params) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         {:ok, summary} <- Operator.requeue_pending_writes(db_path, operator_requeue_opts()) do
      json(conn, summary)
    else
      {:error, :forbidden} ->
        error_response(conn, 403, "operator_control_forbidden", "Surfer operator controls are loopback-only")

      {:error, :disabled} ->
        error_response(conn, 404, "surfer_ledger_disabled", "Surfer run ledger is not configured")

      {:error, reason} ->
        error_response(conn, 500, "surfer_requeue_failed", safe_inspect(reason))
    end
  end

  @spec operator_backup_ledger(Conn.t(), map()) :: Conn.t()
  def operator_backup_ledger(conn, params) do
    with :ok <- require_loopback(conn),
         {:ok, db_path} <- surfer_ledger_path(),
         {:ok, backup} <- Operator.backup_ledger(db_path, label: Map.get(params, "label")) do
      json(conn, backup)
    else
      error -> operator_control_error(conn, error)
    end
  end

  defp verify_discord_interaction(conn, params, raw_body, signature, timestamp, discord, public_keys, received_at_ms) do
    case Discord.Webhook.verify(raw_body, signature, timestamp, public_keys, max_age_seconds: discord.signature_max_age_seconds) do
      :ok ->
        if Discord.Interaction.ping?(params) do
          json(conn, %{type: 1})
        else
          handle_discord_interaction(conn, params, discord, received_at_ms)
        end

      {:error, :missing_signature} ->
        record_signature_failure(:discord, :missing_signature)
        error_response(conn, 401, "missing_signature", "Discord signature is required")

      {:error, :missing_timestamp} ->
        record_signature_failure(:discord, :missing_timestamp)
        error_response(conn, 401, "missing_timestamp", "Discord signature timestamp is required")

      {:error, :missing_public_key} ->
        error_response(conn, 503, "missing_discord_public_key", "Discord public key is required when Discord ingress is enabled")

      {:error, :invalid_signature} ->
        record_signature_failure(:discord, :invalid_signature)
        error_response(conn, 401, "invalid_signature", "Discord signature is invalid")

      {:error, :stale_timestamp} ->
        record_signature_failure(:discord, :stale_timestamp)
        error_response(conn, 401, "stale_timestamp", "Discord signature timestamp is stale")

      {:error, :invalid_timestamp} ->
        record_signature_failure(:discord, :invalid_timestamp)
        error_response(conn, 401, "invalid_timestamp", "Discord signature timestamp is invalid")
    end
  end

  defp handle_discord_interaction(conn, params, discord, received_at_ms) do
    with {:ok, request} <-
           Discord.Interaction.to_run_request(params,
             allowed_guilds: discord.allowed_guilds,
             allowed_channels: discord.allowed_channels
           ),
         :ok <- require_secret(discord.enabled, discord.bot_token, :missing_discord_bot_token) do
      raw_message = put_discord_interaction_retry_deadline(params, received_at_ms)
      claim_and_dispatch_discord_interaction(conn, request, raw_message, discord)
    else
      {:error, :missing_discord_bot_token} ->
        error_response(conn, 503, "missing_discord_bot_token", "Discord bot token is required when Discord ingress is enabled")

      {:error, reason} ->
        discord_interaction_error_response(conn, reason)
    end
  end

  defp discord_interaction_error_response(conn, {:unauthorized_guild, _guild_id}) do
    error_response(conn, 403, "unauthorized_guild", "Discord guild is not allowed")
  end

  defp discord_interaction_error_response(conn, {:unauthorized_channel, _channel_id}) do
    error_response(conn, 403, "unauthorized_channel", "Discord channel is not allowed")
  end

  defp discord_interaction_error_response(conn, :missing_discord_interaction_id) do
    error_response(conn, 400, "missing_discord_interaction_id", "Discord interaction id is required")
  end

  defp discord_interaction_error_response(conn, :missing_discord_message_id) do
    error_response(conn, 400, "missing_discord_message_id", "Discord message id is required")
  end

  defp discord_interaction_error_response(conn, :missing_discord_guild_id) do
    error_response(conn, 400, "missing_discord_guild_id", "Discord guild id is required")
  end

  defp discord_interaction_error_response(conn, :missing_discord_channel_id) do
    error_response(conn, 400, "missing_discord_channel_id", "Discord channel id is required")
  end

  defp discord_interaction_error_response(conn, :missing_discord_lifecycle_run_id) do
    error_response(conn, 400, "missing_discord_lifecycle_run_id", "Discord lifecycle run id is required")
  end

  defp discord_interaction_error_response(conn, :missing_discord_prompt) do
    error_response(conn, 400, "missing_discord_prompt", "Discord command prompt is required")
  end

  defp discord_interaction_error_response(conn, {:unsupported_discord_subcommand, subcommand}) do
    error_response(conn, 400, "unsupported_discord_subcommand", "Unsupported Discord Surfer subcommand: #{safe_inspect(subcommand)}")
  end

  defp discord_interaction_error_response(conn, reason) do
    error_response(conn, 400, "unsupported_discord_interaction", safe_inspect(reason))
  end

  defp claim_and_dispatch_discord_interaction(conn, request, raw_message, discord) do
    case claim_run(request, :discord) do
      {:ok, response} ->
        discord_interaction_dispatch_response(conn, response, request, raw_message, discord)

      {:error, {:ledger_claim_failed, reason}} ->
        error_response(conn, 503, "ledger_claim_failed", "Surfer run ledger claim failed: #{safe_inspect(reason)}")
    end
  end

  defp discord_interaction_dispatch_response(conn, response, request, raw_message, discord) do
    case maybe_dispatch_discord_interaction(response, request, raw_message, discord) do
      :deferred ->
        json(conn, %{type: 5})

      {:immediate_response, message} ->
        json(conn, %{type: 4, data: %{content: message}})

      {:error, :rate_limited} ->
        json(conn, %{type: 4, data: %{content: "Surfer rate limit exceeded. Try again later."}})

      {:error, reason} ->
        error_response(conn, 500, "surfer_dispatch_failed", safe_inspect(reason))
    end
  end

  defp post_linear_started(%RunRequest{} = request) do
    started_at = System.monotonic_time(:millisecond)

    case post_linear_start_activity(request) do
      :ok ->
        emit_time_to_first_activity(request, started_at)

      {:error, reason} ->
        record_pending_linear_started_write(request, reason)

      other ->
        record_pending_linear_started_write(request, {:unexpected_linear_started_result, other})
    end

    post_linear_run_external_url(request)
    :ok
  end

  defp post_linear_start_activity(%RunRequest{} = request) do
    session_id = request.lineage.linear[:agent_session_id]
    activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_activity_fun)

    cond do
      is_function(activity_fun, 2) and is_binary(session_id) ->
        activity_fun.(session_id, request.run_id)

      is_binary(session_id) ->
        Session.started(session_id, request.run_id)

      true ->
        :ok
    end
  end

  defp emit_time_to_first_activity(%RunRequest{} = request, started_at) do
    Metrics.emit(
      :time_to_first_activity_ms,
      %{duration_ms: System.monotonic_time(:millisecond) - started_at},
      %{
        platform: :linear,
        run_id: request.run_id,
        linear_session_id: request.lineage.linear[:agent_session_id]
      }
    )
  end

  defp post_linear_run_external_url(%RunRequest{} = request) do
    session_id = request.lineage.linear[:agent_session_id]
    external_base_url = Config.settings!().surfer.external_base_url

    if is_binary(session_id) and is_binary(external_base_url) do
      urls = [%{label: "Surfer run", url: surfer_run_url(external_base_url, request.run_id)}]

      case update_linear_external_urls(session_id, urls) do
        :ok ->
          :ok

        {:error, reason} ->
          record_pending_external_url_write(request, session_id, urls, reason)
      end
    else
      :ok
    end
  end

  defp update_linear_external_urls(session_id, urls) do
    case Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun) do
      fun when is_function(fun, 2) -> fun.(session_id, urls)
      _ -> Session.update_external_urls(session_id, urls)
    end
  end

  defp surfer_run_url(external_base_url, run_id) do
    external_base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1/surfer/runs/#{run_id}")
  end

  defp record_pending_external_url_write(request, session_id, urls, reason) do
    external_id = "#{session_id}:external_urls:#{request.run_id}"

    payload = %{
      type: "external_urls",
      session_id: session_id,
      external_urls: urls,
      error: safe_inspect(reason)
    }

    Metrics.emit(:platform_write_failures, %{count: 1}, %{
      run_id: request.run_id,
      platform: "linear",
      external_id: external_id,
      reason: safe_inspect(reason)
    })

    record_pending_write(request.run_id, %{
      platform: "linear",
      external_id: external_id,
      idempotency_hash: idempotency_hash(payload),
      payload: payload
    })
  end

  defp record_pending_linear_started_write(%RunRequest{} = request, reason) do
    session_id = linear_lineage_value(request, :agent_session_id)

    if is_binary(session_id) do
      external_id = "#{session_id}:started:#{request.run_id}"

      payload = %{
        type: "started",
        session_id: session_id,
        run_id: request.run_id,
        body: Session.started_body(request.run_id),
        error: safe_inspect(reason)
      }

      Metrics.emit(:platform_write_failures, %{count: 1}, %{
        run_id: request.run_id,
        platform: "linear",
        external_id: external_id,
        reason: safe_inspect(reason)
      })

      record_pending_write(request.run_id, %{
        platform: "linear",
        external_id: external_id,
        idempotency_hash: idempotency_hash(payload),
        payload: payload
      })
    end

    :ok
  end

  defp dispatch_linear_request(%RunRequest{} = request) do
    case Application.get_env(:symphony_elixir, :surfer_linear_dispatch_fun) do
      fun when is_function(fun, 1) -> fun.(request)
      _ -> SymphonyElixir.Orchestrator.dispatch_run(request)
    end
  end

  defp claim_run(%RunRequest{} = request, platform) do
    db_path = Config.settings!().surfer.storage.sqlite_path
    key = RunRequest.idempotency_key(request)

    claim_initialized_run(db_path, key, request, platform)
  end

  defp claim_initialized_run(nil, _key, request, _platform), do: {:ok, %{ok: true, run_id: request.run_id}}
  defp claim_initialized_run("", _key, request, _platform), do: {:ok, %{ok: true, run_id: request.run_id}}

  defp claim_initialized_run(db_path, key, request, platform) do
    case claim_run_with_retry(db_path, key, request, platform, @claim_retry_delays_ms) do
      {:ok, %{status: :claimed, run_id: run_id}} ->
        {:ok, %{ok: true, run_id: run_id}}

      {:ok, %{status: :duplicate, run_id: run_id}} ->
        {:ok, %{ok: true, duplicate: true, run_id: run_id}}

      {:error, reason} ->
        record_ledger_claim_failed(request, platform, reason)
        {:error, {:ledger_claim_failed, reason}}
    end
  end

  defp claim_run_with_retry(db_path, key, request, platform, []) do
    claim_run_once(db_path, key, request, platform)
  end

  defp claim_run_with_retry(db_path, key, request, platform, [delay_ms | remaining_delays]) do
    case claim_run_once(db_path, key, request, platform) do
      {:error, reason} = error ->
        if transient_ledger_claim_error?(reason) do
          Process.sleep(delay_ms)
          claim_run_with_retry(db_path, key, request, platform, remaining_delays)
        else
          error
        end

      result ->
        result
    end
  end

  defp claim_run_once(db_path, key, request, platform) do
    case Application.get_env(:symphony_elixir, :surfer_run_claim_fun) do
      fun when is_function(fun, 4) -> fun.(db_path, key, request, platform: platform)
      _ -> RunLedger.claim_run(db_path, key, request, platform: platform)
    end
  end

  defp transient_ledger_claim_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> then(&(String.contains?(&1, "busy") or String.contains?(&1, "locked") or String.contains?(&1, "timeout")))
  end

  defp record_ledger_claim_failed(%RunRequest{} = request, platform, reason) do
    Logger.warning("Surfer ledger claim failed run_id=#{request.run_id} platform=#{platform}: #{safe_inspect(reason)}")

    Metrics.emit(:ledger_claim_failed, %{count: 1}, %{
      run_id: request.run_id,
      platform: platform,
      reason: safe_inspect(reason)
    })
  end

  defp maybe_dispatch_linear(%{duplicate: true} = response, _request), do: {:ok, response}

  defp maybe_dispatch_linear(response, %RunRequest{} = request) do
    cond do
      surfer_paused?() ->
        paused_linear_response(response, request)

      budget_cap_exceeded?() ->
        budget_cap_linear_response(response, request)

      disk_pressure?(response.run_id) ->
        disk_pressure_linear_response(response, request)

      linear_session_active_run_limited?(response.run_id, request) ->
        linear_session_active_run_limit_response(response, request)

      true ->
        case route_request_for_dispatch(request) do
          {:ok, routed_request} ->
            start_linear_dispatch_task(response, routed_request)

          {:error, reason} ->
            routing_error_linear_response(response, request, reason)
        end
    end
  end

  defp paused_linear_response(response, request) do
    :ok = record_paused_run(response.run_id)
    enqueue_linear_error(request, :surfer_paused)
    {:ok, Map.put(response, :paused, true)}
  end

  defp budget_cap_linear_response(response, request) do
    :ok = record_budget_cap_run(response.run_id)
    enqueue_linear_error(request, :daily_budget_cap_exceeded)
    {:ok, response |> Map.put(:budget_cap, true) |> Map.put(:dispatched, false)}
  end

  defp disk_pressure_linear_response(response, request) do
    :ok = record_disk_pressure_run(response.run_id)
    enqueue_linear_error(request, :workspace_disk_pressure)
    {:ok, response |> Map.put(:disk_pressure, true) |> Map.put(:dispatched, false)}
  end

  defp linear_session_active_run_limit_response(response, request) do
    :ok = record_linear_session_active_run_limit(response.run_id, request)
    enqueue_linear_error(request, :linear_session_active_run_limit)

    {:ok,
     response
     |> Map.put(:linear_session_busy, true)
     |> Map.put(:dispatched, false)}
  end

  defp routing_error_linear_response(response, request, reason) do
    :ok = record_routing_blocked_run(response.run_id, reason)
    enqueue_linear_error(request, reason)

    {:ok,
     response
     |> Map.put(:routing_error, safe_inspect(reason))
     |> Map.put(:dispatched, false)}
  end

  defp start_linear_dispatch_task(response, request) do
    case start_ingress_task(fn ->
           request
           |> post_linear_started()
           |> dispatch_after_linear_started(request)
         end) do
      :ok -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_after_linear_started(:ok, request) do
    case dispatch_linear_request(request) do
      :ok -> :ok
      {:error, reason} -> post_linear_error(request, reason)
    end
  end

  defp maybe_dispatch_discord_interaction(%{duplicate: true}, _request, _raw_message, _discord), do: :deferred

  defp maybe_dispatch_discord_interaction(response, request, raw_message, discord) do
    if surfer_paused?() do
      record_cancelled_run(response.run_id, "Surfer is paused")
      {:immediate_response, "Surfer is paused; request #{response.run_id} was not dispatched."}
    else
      case maybe_dispatch_discord(response, request, raw_message, discord) do
        :ok -> :deferred
        other -> other
      end
    end
  end

  defp maybe_dispatch_discord(%{duplicate: true}, _request, _raw_message, _discord), do: :ok

  defp maybe_dispatch_discord(response, request, raw_message, discord) do
    cond do
      surfer_paused?() ->
        record_cancelled_run(response.run_id, "Surfer is paused")
        post_discord_interaction_response(raw_message, "Surfer is paused; request #{response.run_id} was not dispatched.", response.run_id)

      budget_cap_exceeded?() ->
        record_budget_cap_run(response.run_id)

        post_discord_interaction_response(
          raw_message,
          "Surfer budget cap is exhausted; request #{response.run_id} was not dispatched.",
          response.run_id
        )

      disk_pressure?(response.run_id) ->
        record_disk_pressure_run(response.run_id)

        post_discord_interaction_response(
          raw_message,
          "Surfer workspace disk pressure is too high; request #{response.run_id} was not dispatched.",
          response.run_id
        )

      discord_rate_limited?(request, discord) ->
        record_cancelled_run(response.run_id, "Discord rate limit exceeded")
        {:error, :rate_limited}

      true ->
        route_and_dispatch_discord(response, request, raw_message)
    end
  end

  defp route_and_dispatch_discord(response, request, raw_message) do
    case route_request_for_dispatch(request) do
      {:ok, routed_request} ->
        handle_discord_request(routed_request, raw_message, fn ->
          post_discord_interaction_response(raw_message, "Surfer accepted #{response.run_id}.", response.run_id)
        end)

      {:error, reason} ->
        record_routing_blocked_run(response.run_id, reason)

        post_discord_interaction_response(
          raw_message,
          discord_routing_error_message(response.run_id, reason),
          response.run_id
        )
    end
  end

  defp discord_routing_error_message(run_id, {:ambiguous_repository, repositories}) when is_list(repositories) do
    case repositories do
      [] ->
        "Surfer needs repository routing clarification for #{run_id}: no repository could be selected."

      _ ->
        "Surfer needs repository routing clarification for #{run_id}: ambiguous repository. Candidates: #{Enum.join(repositories, ", ")}."
    end
  end

  defp discord_routing_error_message(run_id, {:unknown_repository, repository}) do
    "Surfer needs repository routing clarification for #{run_id}: unknown repository #{repository}."
  end

  defp discord_routing_error_message(run_id, reason) do
    "Surfer needs repository routing clarification for #{run_id}: #{safe_inspect(reason)}."
  end

  defp handle_discord_request(%RunRequest{request: %{mode: :issue_create}} = request, raw_message, after_success) do
    start_ingress_task(fn ->
      case create_linear_issue_from_discord(raw_message) do
        {:ok, _issue} -> after_success.()
        {:error, reason} -> post_discord_error(request, reason)
      end
    end)
  end

  defp handle_discord_request(%RunRequest{source: %{platform: :discord}, request: %{mode: :durable_task}} = request, raw_message, after_success) do
    start_ingress_task(fn ->
      issue_message = discord_message_for_request(request, raw_message)

      with {:ok, issue} <- create_linear_issue_from_discord(issue_message),
           linked_request <- attach_linear_issue(request, issue),
           :ok <- persist_linear_issue_link(linked_request, issue),
           :ok <- dispatch_discord_request(linked_request) do
        after_success.()
      else
        {:error, reason} -> post_discord_error(request, reason)
      end
    end)
  end

  defp handle_discord_request(%RunRequest{request: %{mode: :lifecycle_control}} = request, raw_message, _after_success) do
    start_ingress_task(fn ->
      record_lifecycle_control_status(request.run_id, "running", "Discord lifecycle control started")

      case handle_lifecycle_control(request) do
        {:ok, message} ->
          post_discord_interaction_response(raw_message, message, request.run_id)
          record_lifecycle_control_status(request.run_id, "completed", "Discord lifecycle control completed")

        {:error, reason} ->
          post_discord_error(request, reason)
          record_lifecycle_control_status(request.run_id, "failed", reason)
      end
    end)
  end

  defp handle_discord_request(%RunRequest{} = request, _raw_message, after_success) do
    start_ingress_task(fn ->
      case dispatch_discord_request(request) do
        :ok -> after_success.()
        {:error, reason} -> post_discord_error(request, reason)
      end
    end)
  end

  defp discord_message_for_request(%RunRequest{} = request, raw_message) when is_map(raw_message) do
    %{
      "id" => Map.get(raw_message, "id") || request.lineage.discord[:message_id] || request.run_id,
      "guild_id" => Map.get(raw_message, "guild_id") || request.lineage.discord[:guild_id],
      "channel_id" => Map.get(raw_message, "channel_id") || request.lineage.discord[:channel_id],
      "thread_id" => Map.get(raw_message, "thread_id") || request.lineage.discord[:thread_id],
      "content" => request.request[:body] || Map.get(raw_message, "content") || ""
    }
  end

  defp attach_linear_issue(%RunRequest{} = request, issue) when is_map(issue) do
    linear_lineage =
      Map.merge(request.lineage.linear || %{}, %{
        issue_id: issue_value(issue, :id),
        issue_identifier: issue_value(issue, :identifier)
      })

    issue_struct = %Issue{
      id: issue_value(issue, :id),
      identifier: issue_value(issue, :identifier),
      title: issue_value(issue, :title),
      url: issue_value(issue, :url)
    }

    %{request | lineage: put_in(request.lineage, [:linear], linear_lineage), issue: issue_struct}
  end

  defp persist_linear_issue_link(%RunRequest{} = request, issue) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        with :ok <- RunLedger.upsert_run(db_path, request, status: "queued") do
          record_linear_issue_link(db_path, request.run_id, issue)
        end

      {:error, :disabled} ->
        :ok
    end
  end

  defp record_linear_issue_link(db_path, run_id, issue) do
    case issue_value(issue, :id) do
      issue_id when is_binary(issue_id) ->
        RunLedger.record_link(db_path, run_id, %{
          platform: "linear",
          kind: "issue",
          external_id: issue_id,
          url: issue_value(issue, :url)
        })

      _ ->
        :ok
    end
  end

  defp issue_value(issue, key) when is_map(issue), do: Map.get(issue, key) || Map.get(issue, to_string(key))

  defp handle_lifecycle_control(%RunRequest{request: %{action: :cancel, run_id: run_id}}) when is_binary(run_id) do
    with {:ok, db_path} <- surfer_ledger_path(),
         :ok <- Lifecycle.cancel(db_path, run_id, actor: "discord", reason: "cancelled from Discord", notify_source?: false),
         :ok <- cancel_active_run(run_id, actor: "discord", reason: "cancelled from Discord") do
      {:ok, "Surfer run #{run_id} cancelled."}
    end
  end

  defp handle_lifecycle_control(%RunRequest{request: %{action: :retry, run_id: run_id}}) when is_binary(run_id) do
    with {:ok, db_path} <- surfer_ledger_path(),
         {:ok, retry} <- Lifecycle.retry(db_path, run_id, actor: "discord") do
      {:ok, "Surfer retry #{retry.run_id} created for #{run_id}."}
    end
  end

  defp handle_lifecycle_control(%RunRequest{request: %{action: :takeover, run_id: run_id}}) when is_binary(run_id) do
    with {:ok, db_path} <- surfer_ledger_path(),
         :ok <- Lifecycle.takeover(db_path, run_id, actor: "discord", reason: "taken over from Discord"),
         :ok <- stop_active_run_for_takeover(run_id, actor: "discord", reason: "taken over from Discord") do
      {:ok, "Surfer run #{run_id} taken over for human review."}
    end
  end

  defp handle_lifecycle_control(_request), do: {:error, :unsupported_lifecycle_control}

  defp record_lifecycle_control_status(run_id, status, reason) when is_binary(run_id) and is_binary(status) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        case RunLedger.update_status(db_path, run_id, status,
               reason: safe_inspect(reason),
               actor: "discord",
               platform: "discord"
             ) do
          :ok ->
            :ok

          {:error, status_reason} ->
            Logger.warning("Failed to record Discord lifecycle control status run_id=#{run_id} status=#{status}: #{safe_inspect(status_reason)}")
        end

      {:error, :disabled} ->
        :ok
    end
  end

  defp cancel_active_run(run_id, opts) do
    server = Application.get_env(:symphony_elixir, :surfer_orchestrator_server, Orchestrator)
    opts = Keyword.put(opts, :record_status, false)

    case Orchestrator.cancel_run(server, run_id, opts) do
      {:ok, _cancelled} -> :ok
      {:error, :not_running} -> :ok
      :unavailable -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_active_run_for_takeover(run_id, opts) do
    server = Application.get_env(:symphony_elixir, :surfer_orchestrator_server, Orchestrator)
    opts = Keyword.put(opts, :record_status, false)

    case Orchestrator.cancel_run(server, run_id, opts) do
      {:ok, _stopped} -> :ok
      {:error, :not_running} -> :ok
      :unavailable -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_linear_issue_from_discord(raw_message) do
    issue_fun =
      Application.get_env(:symphony_elixir, :surfer_linear_issue_create_fun) ||
        fn attrs ->
          linear = Config.settings!().surfer.platforms.linear

          IssueCreator.create(attrs,
            team_id: linear.team_id,
            project_id: linear.project_id
          )
        end

    Discord.IssueBridge.create_linear_issue(raw_message,
      create_issue_fun: issue_fun,
      post_message_fun: &post_discord_channel_message/2
    )
  end

  defp dispatch_discord_request(%RunRequest{} = request) do
    case Application.get_env(:symphony_elixir, :surfer_discord_dispatch_fun) do
      fun when is_function(fun, 1) -> fun.(request)
      _ -> SymphonyElixir.Orchestrator.dispatch_run(request)
    end
  end

  defp route_request_for_dispatch(%RunRequest{request: %{mode: mode}} = request)
       when mode in [:issue_create, :lifecycle_control, "issue_create", "lifecycle_control"] do
    {:ok, request}
  end

  defp route_request_for_dispatch(%RunRequest{} = request) do
    case Config.settings!().surfer.repositories do
      [] ->
        {:ok, request}

      repositories ->
        with {:ok, routed_request} <- RunRequest.route(request, repositories),
             :ok <- persist_routed_run(routed_request) do
          {:ok, routed_request}
        end
    end
  end

  defp persist_routed_run(%RunRequest{} = request) do
    case surfer_ledger_path() do
      {:ok, db_path} -> RunLedger.upsert_run(db_path, request, status: "queued")
      {:error, :disabled} -> :ok
    end
  end

  defp enqueue_linear_error(%RunRequest{} = request, reason) do
    case start_ingress_task(fn -> post_linear_error(request, reason) end) do
      :ok ->
        :ok

      {:error, task_reason} ->
        record_pending_linear_error_task_start_failure(request, reason, task_reason)
    end
  end

  defp post_linear_error(%RunRequest{} = request, reason) do
    with {:ok, session_id, body} <- linear_error_activity(request, reason) do
      result = post_linear_session_activity(session_id, :error, body)
      record_pending_linear_activity_write(request, session_id, :error, body, result)
    end

    :ok
  end

  defp record_pending_linear_error_task_start_failure(%RunRequest{} = request, reason, task_reason) do
    with {:ok, session_id, body} <- linear_error_activity(request, reason) do
      record_pending_linear_activity_write(
        request,
        session_id,
        :error,
        body,
        {:error, {:linear_error_task_start_failed, task_reason}}
      )
    end

    :ok
  end

  defp linear_error_activity(%RunRequest{} = request, reason) do
    session_id = linear_lineage_value(request, :agent_session_id)
    body = "Surfer dispatch failed: #{safe_inspect(reason)}"

    if is_binary(session_id) do
      {:ok, session_id, body}
    else
      :skip
    end
  end

  defp linear_lineage_value(%RunRequest{} = request, key) when is_atom(key) do
    lineage = request.lineage.linear || %{}
    Map.get(lineage, key) || Map.get(lineage, to_string(key))
  end

  defp post_linear_session_activity(session_id, type, body) when is_atom(type) and is_binary(body) do
    case Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun) do
      fun when is_function(fun, 3) ->
        fun.(session_id, type, body)

      _ ->
        case type do
          :error -> Session.error(session_id, body)
        end
    end
  end

  defp record_pending_linear_activity_write(_request, _session_id, _type, _body, :ok), do: :ok

  defp record_pending_linear_activity_write(%RunRequest{} = request, session_id, type, body, {:error, reason}) do
    external_id = "#{session_id}:#{type}:#{request.run_id}"

    payload = %{
      type: to_string(type),
      session_id: session_id,
      body: body,
      error: safe_inspect(reason)
    }

    Metrics.emit(:platform_write_failures, %{count: 1}, %{
      run_id: request.run_id,
      platform: "linear",
      external_id: external_id,
      reason: safe_inspect(reason)
    })

    record_pending_write(request.run_id, %{
      platform: "linear",
      external_id: external_id,
      idempotency_hash: idempotency_hash(payload),
      payload: payload
    })
  end

  defp record_pending_linear_activity_write(_request, _session_id, _type, _body, _result), do: :ok

  defp post_discord_error(%RunRequest{} = request, reason) do
    channel_id = request.lineage.discord[:channel_id]

    if is_binary(channel_id) do
      body = "Surfer request failed: #{safe_inspect(reason)}"

      case post_discord_channel_message(channel_id, body) do
        :ok ->
          :ok

        {:error, post_reason} ->
          Logger.warning("Discord error notification failed run_id=#{request.run_id} channel_id=#{channel_id}: #{safe_inspect(post_reason)}")

          record_pending_discord_channel_write(request.run_id, channel_id, body, post_reason, "error")

        other ->
          post_reason = {:unexpected_discord_post_result, other}

          Logger.warning("Discord error notification returned unexpected result run_id=#{request.run_id} channel_id=#{channel_id}: #{safe_inspect(other)}")

          record_pending_discord_channel_write(request.run_id, channel_id, body, post_reason, "error")
      end
    end

    :ok
  end

  defp post_discord_channel_message(channel_id, body) do
    case Application.get_env(:symphony_elixir, :surfer_discord_post_fun) do
      fun when is_function(fun, 2) ->
        fun.(channel_id, body)

      _ ->
        bot_token = Config.settings!().surfer.platforms.discord.bot_token
        Discord.Notifier.post_message(channel_id, body, bot_token: bot_token)
    end
  end

  defp post_discord_interaction_response(%{"application_id" => application_id, "token" => token} = raw_message, body, run_id)
       when is_binary(application_id) and is_binary(token) and is_binary(body) do
    case post_discord_interaction_response_until(
           application_id,
           token,
           body,
           discord_interaction_retry_deadline_ms(raw_message)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        handle_discord_interaction_response_failure(raw_message, body, reason, run_id)
    end
  end

  defp post_discord_interaction_response(_raw_message, _body, _run_id), do: :ok

  defp post_discord_interaction_response_until(application_id, token, body, deadline_ms) do
    case attempt_discord_interaction_response(application_id, token, body) do
      :ok ->
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          maybe_sleep_discord_interaction_retry(deadline_ms)
          post_discord_interaction_response_until(application_id, token, body, deadline_ms)
        else
          {:error, reason}
        end
    end
  end

  defp attempt_discord_interaction_response(application_id, token, body) do
    result =
      case Application.get_env(:symphony_elixir, :surfer_discord_interaction_response_fun) do
        fun when is_function(fun, 3) ->
          fun.(application_id, token, body)

        _ ->
          Discord.Notifier.edit_original_interaction_response(application_id, token, body)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_discord_response_result, other}}
    end
  end

  defp put_discord_interaction_retry_deadline(raw_message, received_at_ms) when is_map(raw_message) and is_integer(received_at_ms) do
    Map.put(raw_message, @discord_interaction_retry_deadline_key, discord_interaction_retry_deadline_ms(received_at_ms))
  end

  defp discord_interaction_retry_deadline_ms(%{} = raw_message) do
    case Map.get(raw_message, @discord_interaction_retry_deadline_key) do
      deadline_ms when is_integer(deadline_ms) -> deadline_ms
      _value -> discord_interaction_retry_deadline_ms(System.monotonic_time(:millisecond))
    end
  end

  defp discord_interaction_retry_deadline_ms(received_at_ms) when is_integer(received_at_ms) do
    received_at_ms +
      Application.get_env(
        :symphony_elixir,
        :surfer_discord_interaction_retry_window_ms,
        @discord_interaction_token_window_ms
      )
  end

  defp maybe_sleep_discord_interaction_retry(deadline_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining_ms = deadline_ms - now_ms

    case Application.get_env(
           :symphony_elixir,
           :surfer_discord_interaction_retry_backoff_ms,
           @discord_interaction_response_retry_backoff_ms
         ) do
      ms when is_integer(ms) and ms > 0 and remaining_ms > 0 -> Process.sleep(min(ms, remaining_ms))
      _ -> :ok
    end
  end

  defp handle_discord_interaction_response_failure(raw_message, body, reason, run_id) when is_map(raw_message) do
    application_id = Map.get(raw_message, "application_id")
    interaction_id = Map.get(raw_message, "id")
    channel_id = Map.get(raw_message, "channel_id")

    Logger.warning("Discord interaction response failed#{run_log_context(run_id)} application_id=#{application_id}: #{safe_inspect(reason)}")

    Metrics.emit(:discord_followup_failed, %{count: 1}, %{
      platform: :discord,
      application_id: application_id,
      interaction_id: interaction_id,
      channel_id: channel_id,
      reason: safe_inspect(reason)
    })

    maybe_post_discord_interaction_fallback(channel_id, body, run_id)
  end

  defp maybe_post_discord_interaction_fallback(channel_id, body, run_id) when is_binary(channel_id) and is_binary(body) do
    case post_discord_channel_message(channel_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Discord interaction fallback channel post failed#{run_log_context(run_id)} channel_id=#{channel_id}: #{safe_inspect(reason)}")
        record_pending_discord_channel_write(run_id, channel_id, body, reason, "interaction_fallback")

      other ->
        reason = {:unexpected_discord_post_result, other}
        Logger.warning("Discord interaction fallback channel post returned unexpected result#{run_log_context(run_id)} channel_id=#{channel_id}: #{safe_inspect(other)}")
        record_pending_discord_channel_write(run_id, channel_id, body, reason, "interaction_fallback")
    end
  end

  defp maybe_post_discord_interaction_fallback(_channel_id, _body, _run_id) do
    :ok
  end

  defp record_pending_discord_channel_write(run_id, channel_id, body, reason, kind)
       when is_binary(run_id) and is_binary(channel_id) and is_binary(body) and is_binary(kind) do
    external_id = "#{channel_id}:#{kind}:#{run_id}"

    payload = %{
      type: "channel_message",
      channel_id: channel_id,
      body: body,
      error: safe_inspect(reason)
    }

    Metrics.emit(:platform_write_failures, %{count: 1}, %{
      run_id: run_id,
      platform: "discord",
      external_id: external_id,
      reason: safe_inspect(reason)
    })

    record_pending_write(run_id, %{
      platform: "discord",
      external_id: external_id,
      idempotency_hash: idempotency_hash(payload),
      payload: payload
    })
  end

  defp record_pending_discord_channel_write(_run_id, _channel_id, _body, _reason, _kind), do: :ok

  defp run_log_context(run_id) when is_binary(run_id) and run_id != "", do: " run_id=#{run_id}"
  defp run_log_context(_run_id), do: ""

  defp record_pending_write(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        case RunLedger.record_pending_write(db_path, run_id, attrs) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to record pending Surfer platform write run_id=#{run_id}: #{safe_inspect(reason)}")
        end

      {:error, :disabled} ->
        :ok
    end
  end

  defp idempotency_hash(payload) do
    RunLedger.pending_write_idempotency_hash(payload)
  end

  defp record_signature_failure(platform, reason) do
    Metrics.emit(:signature_failures, %{count: 1}, %{platform: platform, reason: reason})
  end

  defp emit_webhook_ack(platform, route, started_at, %Conn{} = conn) do
    Metrics.emit(
      :webhook_ack_ms,
      %{duration_ms: System.monotonic_time(:millisecond) - started_at},
      %{platform: platform, route: route, status: conn.status}
    )
  end

  defp start_ingress_task(fun) when is_function(fun, 0) do
    ledger_path = configured_surfer_ledger_path()

    wrapped_fun = fn -> with_task_ledger_path(ledger_path, fun) end

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, wrapped_fun) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_task_ledger_path(ledger_path, fun) do
    previous = Process.get(@task_ledger_path_key, :unset)
    Process.put(@task_ledger_path_key, ledger_path)

    try do
      fun.()
    after
      case previous do
        :unset -> Process.delete(@task_ledger_path_key)
        value -> Process.put(@task_ledger_path_key, value)
      end
    end
  end

  defp record_routing_blocked_run(run_id, reason) when is_binary(run_id) do
    case surfer_ledger_path() do
      {:ok, path} ->
        RunLedger.update_status(path, run_id, "awaiting_input",
          reason: "repository routing failed",
          actor: "surfer",
          error_code: "routing_failed",
          error_message: safe_inspect(reason)
        )
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record Surfer routing block run_id=#{run_id}: #{safe_inspect(reason)}")
            :ok
        end

      {:error, :disabled} ->
        :ok
    end
  end

  defp record_paused_run(run_id), do: record_cancelled_run(run_id, "Surfer is paused")

  defp record_cancelled_run(run_id, reason) when is_binary(run_id) do
    case Config.settings!().surfer.storage.sqlite_path do
      path when is_binary(path) and path != "" ->
        case RunLedger.update_status(path, run_id, "cancelled", reason: reason, actor: "surfer") do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp record_budget_cap_run(run_id) when is_binary(run_id) do
    Metrics.emit(:budget_cap_hits, %{count: 1}, %{run_id: run_id})

    case Config.settings!().surfer.storage.sqlite_path do
      path when is_binary(path) and path != "" ->
        case RunLedger.update_status(path, run_id, "failed",
               reason: "daily budget cap exceeded",
               actor: "surfer",
               error_code: "budget_cap",
               error_message: "Daily Codex budget cap exceeded"
             ) do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp record_disk_pressure_run(run_id) when is_binary(run_id) do
    case Config.settings!().surfer.storage.sqlite_path do
      path when is_binary(path) and path != "" ->
        case RunLedger.update_status(path, run_id, "failed",
               reason: "workspace disk pressure",
               actor: "surfer",
               error_code: "disk_pressure",
               error_message: "Workspace disk pressure is above the configured threshold"
             ) do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp record_linear_session_active_run_limit(run_id, %RunRequest{} = request) when is_binary(run_id) do
    session_id = request.lineage.linear[:agent_session_id]

    case surfer_ledger_path() do
      {:ok, path} ->
        RunLedger.update_status(path, run_id, "awaiting_input",
          reason: "Linear agent session already has an active Surfer run",
          actor: "surfer",
          error_code: "linear_session_active_run_limit",
          error_message: "Linear agent session #{session_id} already has an active Surfer run"
        )
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record Linear session active-run limit run_id=#{run_id}: #{safe_inspect(reason)}")
            :ok
        end

      {:error, :disabled} ->
        :ok
    end
  end

  defp budget_cap_exceeded? do
    settings = Config.settings!()

    with {:ok, db_path} <- surfer_ledger_path(),
         {:error, {:daily_budget_cap_exceeded, _metadata}} <-
           Budget.check_daily_cap(db_path, settings.surfer.codex.daily_budget_usd) do
      true
    else
      _ -> false
    end
  end

  defp disk_pressure?(run_id) do
    settings = Config.settings!()
    workspace_root = settings.surfer.workspace_root || settings.workspace.root
    max_used_percent = settings.surfer.storage.disk_pressure_max_used_percent

    if is_integer(max_used_percent) do
      opts =
        case Application.get_env(:symphony_elixir, :surfer_disk_usage_fun) do
          fun when is_function(fun, 1) -> [disk_usage_fun: fun]
          _ -> []
        end

      case WorkspaceLifecycle.disk_pressure?(workspace_root, max_used_percent, opts) do
        {:ok, pressure?} ->
          pressure?

        {:error, reason} ->
          Logger.warning("Unable to check Surfer workspace disk pressure#{run_log_context(run_id)}: #{safe_inspect(reason)}")
          true
      end
    else
      false
    end
  end

  defp linear_session_active_run_limited?(run_id, %RunRequest{} = request) when is_binary(run_id) do
    session_id = request.lineage.linear[:agent_session_id]

    if is_binary(session_id) and session_id != "" do
      with {:ok, db_path} <- surfer_ledger_path(),
           {:ok, count} <- RunLedger.count_open_linear_session_runs(db_path, session_id, exclude_run_id: run_id) do
        count > 0
      else
        _ -> false
      end
    else
      false
    end
  end

  defp discord_rate_limited?(%RunRequest{request: %{mode: :lifecycle_control}}, _discord), do: false

  defp discord_rate_limited?(%RunRequest{} = request, discord) do
    discord_user_cooldown_limited?(request, discord) or
      discord_channel_queue_limited?(request, discord) or
      discord_daily_run_limited?(request, discord)
  end

  defp discord_user_cooldown_limited?(%RunRequest{} = request, discord) do
    cooldown = Map.get(discord, :per_user_cooldown_seconds, 30)
    user_id = request.request[:requested_by]

    cond do
      not is_integer(cooldown) or cooldown <= 0 ->
        false

      not is_binary(user_id) or user_id == "" ->
        false

      true ->
        rate_limited?({:discord_user, user_id}, cooldown)
    end
  end

  defp discord_channel_queue_limited?(%RunRequest{} = request, discord) do
    limit = Map.get(discord, :per_channel_queued_limit, 3)
    channel_id = request.lineage.discord[:channel_id]

    cond do
      not is_integer(limit) or limit <= 0 ->
        false

      not is_binary(channel_id) or channel_id == "" ->
        false

      true ->
        with {:ok, db_path} <- surfer_ledger_path(),
             {:ok, count} <- RunLedger.count_open_discord_channel_runs(db_path, channel_id) do
          count > limit
        else
          _ -> false
        end
    end
  end

  defp discord_daily_run_limited?(%RunRequest{request: %{mode: :lifecycle_control}}, _discord), do: false

  defp discord_daily_run_limited?(%RunRequest{} = request, discord) do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

    discord_user_daily_limited?(request, discord, today_start) or
      discord_channel_daily_limited?(request, discord, today_start)
  end

  defp discord_user_daily_limited?(%RunRequest{} = request, discord, today_start) do
    limit = Map.get(discord, :per_user_daily_run_limit)
    user_id = request.request[:requested_by]

    cond do
      not positive_integer?(limit) ->
        false

      not is_binary(user_id) or user_id == "" ->
        false

      true ->
        with {:ok, db_path} <- surfer_ledger_path(),
             {:ok, count} <- RunLedger.count_discord_user_runs_since(db_path, user_id, today_start) do
          count > limit
        else
          _ -> false
        end
    end
  end

  defp discord_channel_daily_limited?(%RunRequest{} = request, discord, today_start) do
    limit = Map.get(discord, :per_channel_daily_run_limit)
    channel_id = request.lineage.discord[:channel_id]

    cond do
      not positive_integer?(limit) ->
        false

      not is_binary(channel_id) or channel_id == "" ->
        false

      true ->
        with {:ok, db_path} <- surfer_ledger_path(),
             {:ok, count} <- RunLedger.count_discord_channel_runs_since(db_path, channel_id, today_start) do
          count > limit
        else
          _ -> false
        end
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp rate_limited?(key, cooldown_seconds) do
    table = rate_limit_table()
    now = System.monotonic_time(:second)

    case :ets.lookup(table, key) do
      [{^key, last_seen}] when now - last_seen < cooldown_seconds ->
        true

      _ ->
        :ets.insert(table, {key, now})
        false
    end
  end

  defp rate_limit_table do
    case :ets.whereis(:symphony_surfer_discord_rate_limits) do
      :undefined ->
        :ets.new(:symphony_surfer_discord_rate_limits, [:named_table, :public, read_concurrency: true])

      table ->
        table
    end
  end

  defp require_secret(false, _value, _error), do: :ok
  defp require_secret(true, values, _error) when is_list(values) and values != [], do: :ok
  defp require_secret(true, value, _error) when is_binary(value) and value != "", do: :ok
  defp require_secret(true, _value, error), do: {:error, error}

  defp require_platform_enabled(true), do: :ok
  defp require_platform_enabled(_enabled), do: {:error, :platform_disabled}

  defp require_raw_body(%Conn{private: %{raw_body: raw_body}}) when is_binary(raw_body) and raw_body != "" do
    {:ok, raw_body}
  end

  defp require_raw_body(_conn), do: {:error, :missing_raw_body}

  defp require_configured_path(%Conn{request_path: request_path}, configured_path) do
    if request_path == configured_path, do: :ok, else: {:error, :unconfigured_webhook_path}
  end

  defp configured_path(path, default) when is_binary(path) do
    case String.trim(path) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp configured_path(_path, default), do: default

  defp linear_webhook_secret_slots(linear) do
    [
      {:current, Map.get(linear, :webhook_secret)},
      {:next, Map.get(linear, :webhook_secret_next)}
    ]
    |> Enum.filter(fn {_slot, secret} -> is_binary(secret) and String.trim(secret) != "" end)
  end

  defp discord_message_ingress_secret_slots(discord) do
    [
      {:current, Map.get(discord, :message_ingress_secret)},
      {:next, Map.get(discord, :message_ingress_secret_next)}
    ]
    |> Enum.filter(fn {_slot, secret} -> is_binary(secret) and String.trim(secret) != "" end)
  end

  defp discord_public_key_slots(discord) do
    [
      {:current, Map.get(discord, :public_key)},
      {:next, Map.get(discord, :public_key_next)}
    ]
    |> Enum.filter(fn {_slot, public_key} -> is_binary(public_key) and String.trim(public_key) != "" end)
  end

  defp operator_retry_opts(params) do
    opts = [actor: "operator:http"]

    case Map.get(params, "nonce") do
      nonce when is_binary(nonce) and nonce != "" -> Keyword.put(opts, :nonce, nonce)
      _ -> opts
    end
  end

  defp operator_requeue_opts do
    case Application.get_env(:symphony_elixir, :surfer_pending_write_retry_fun) do
      fun when is_function(fun, 1) -> [actor: "operator:http", retry_fun: fun]
      _ -> [actor: "operator:http"]
    end
  end

  defp surfer_paused? do
    Operator.paused?(configured_surfer_paused?())
  end

  defp configured_surfer_paused? do
    Config.settings!().surfer.paused
  end

  defp operator_control_error(conn, {:error, :forbidden}) do
    error_response(conn, 403, "operator_control_forbidden", "Surfer operator controls are loopback-only")
  end

  defp operator_control_error(conn, {:error, :disabled}) do
    error_response(conn, 404, "surfer_ledger_disabled", "Surfer run ledger is not configured")
  end

  defp operator_control_error(conn, {:error, :not_found}) do
    error_response(conn, 404, "surfer_run_not_found", "Surfer run was not found")
  end

  defp operator_control_error(conn, {:error, {:invalid_transition, _from, _to} = reason}) do
    error_response(conn, 409, "surfer_invalid_transition", safe_inspect(reason))
  end

  defp operator_control_error(conn, {:error, {:retry_requires_failed_run, _status} = reason}) do
    error_response(conn, 409, "surfer_retry_requires_failed_run", safe_inspect(reason))
  end

  defp operator_control_error(conn, {:error, :backup_exists}) do
    error_response(conn, 409, "surfer_backup_exists", "Surfer ledger backup already exists")
  end

  defp operator_control_error(conn, {:error, {:invalid_backup_label, _label} = reason}) do
    error_response(conn, 400, "surfer_invalid_backup_label", safe_inspect(reason))
  end

  defp operator_control_error(conn, {:error, reason}) do
    error_response(conn, 500, "surfer_operator_control_failed", safe_inspect(reason))
  end

  defp surfer_ledger_path do
    case Process.get(@task_ledger_path_key, :unset) do
      :unset -> configured_surfer_ledger_path()
      ledger_path -> ledger_path
    end
  end

  defp configured_surfer_ledger_path do
    case Config.settings!().surfer.storage.sqlite_path do
      path when is_binary(path) ->
        if String.trim(path) == "", do: {:error, :disabled}, else: {:ok, path}

      _ ->
        {:error, :disabled}
    end
  end

  defp require_loopback(%Conn{remote_ip: remote_ip}) do
    if loopback?(remote_ip), do: :ok, else: {:error, :forbidden}
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false

  defp safe_inspect(reason) do
    reason
    |> SecretRedactor.redact()
    |> inspect()
    |> SecretRedactor.redact_text()
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp not_found_response(conn), do: error_response(conn, 404, "not_found", "Route not found")
end
