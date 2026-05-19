defmodule SymphonyElixir.SurferWebhookControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.Surfer.{Budget, RunLedger, RunRequest}
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    dispatch_fun = Application.get_env(:symphony_elixir, :surfer_linear_dispatch_fun)
    activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_activity_fun)
    session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    external_urls_fun = Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun)
    discord_dispatch_fun = Application.get_env(:symphony_elixir, :surfer_discord_dispatch_fun)
    linear_issue_create_fun = Application.get_env(:symphony_elixir, :surfer_linear_issue_create_fun)
    discord_post_fun = Application.get_env(:symphony_elixir, :surfer_discord_post_fun)
    discord_interaction_response_fun = Application.get_env(:symphony_elixir, :surfer_discord_interaction_response_fun)

    discord_interaction_retry_backoff_ms =
      Application.get_env(:symphony_elixir, :surfer_discord_interaction_retry_backoff_ms)

    pending_write_retry_fun = Application.get_env(:symphony_elixir, :surfer_pending_write_retry_fun)
    run_claim_fun = Application.get_env(:symphony_elixir, :surfer_run_claim_fun)
    runtime_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    disk_usage_fun = Application.get_env(:symphony_elixir, :surfer_disk_usage_fun)

    endpoint_config
    |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    |> then(&Application.put_env(:symphony_elixir, Endpoint, &1))

    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      restore_app_env(:surfer_linear_dispatch_fun, dispatch_fun)
      restore_app_env(:surfer_linear_activity_fun, activity_fun)
      restore_app_env(:surfer_linear_session_activity_fun, session_activity_fun)
      restore_app_env(:surfer_linear_external_urls_fun, external_urls_fun)
      restore_app_env(:surfer_discord_dispatch_fun, discord_dispatch_fun)
      restore_app_env(:surfer_linear_issue_create_fun, linear_issue_create_fun)
      restore_app_env(:surfer_discord_post_fun, discord_post_fun)
      restore_app_env(:surfer_discord_interaction_response_fun, discord_interaction_response_fun)
      restore_app_env(:surfer_discord_interaction_retry_backoff_ms, discord_interaction_retry_backoff_ms)
      restore_app_env(:surfer_pending_write_retry_fun, pending_write_retry_fun)
      restore_app_env(:surfer_run_claim_fun, run_claim_fun)
      restore_app_env(:surfer_runtime_pause, runtime_pause)
      restore_app_env(:surfer_disk_usage_fun, disk_usage_fun)
    end)

    :ok
  end

  test "Linear webhook verifies raw body and dispatches normalized run" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")
    parent = self()
    handler_id = {__MODULE__, self(), :linear_webhook_ack_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :webhook_ack_ms],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    first_activity_handler_id = {__MODULE__, self(), :linear_first_activity_metric}

    :telemetry.attach(
      first_activity_handler_id,
      [:symphony, :surfer, :time_to_first_activity_ms],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :telemetry.detach(first_activity_handler_id) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn session_id, run_id ->
      send(parent, {:started, session_id, run_id})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        type: "AgentSessionEvent",
        organizationId: "org-1",
        agentSession: %{
          id: "session-1",
          issue: %{id: "issue-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert json_response(conn, 202)["ok"] == true
    assert_receive {:started, "session-1", run_id}
    assert_receive {:dispatch, request}
    assert request.lineage.linear.agent_session_id == "session-1"
    assert run_id == request.run_id
    assert_receive {:telemetry, [:symphony, :surfer, :webhook_ack_ms], %{duration_ms: duration_ms}, ack_metadata}
    assert duration_ms >= 0
    assert ack_metadata.platform == :linear
    assert ack_metadata.route == "/webhooks/linear/agent"

    first_activity_event = [:symphony, :surfer, :time_to_first_activity_ms]

    assert_receive {
      :telemetry,
      ^first_activity_event,
      %{duration_ms: first_activity_ms},
      first_activity_metadata
    }

    assert first_activity_ms >= 0
    assert first_activity_metadata.platform == :linear
    assert first_activity_metadata.run_id == request.run_id
    assert first_activity_metadata.linear_session_id == "session-1"
  end

  test "Linear webhook uses the configured webhook path only" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")
    parent = self()

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_path: /internal/surfer/linear
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:linear_dispatch, request.run_id})
      :ok
    end)

    body = linear_agent_body("webhook-custom-path-1", "session-custom-path-1", "issue-custom-path-1")
    signature = linear_signature(body, "secret")

    custom_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/internal/surfer/linear", body)

    assert %{"ok" => true, "run_id" => run_id} = json_response(custom_conn, 202)
    assert_receive {:linear_dispatch, ^run_id}

    default_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert json_response(default_conn, 404) == %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
    refute_receive {:linear_dispatch, _run_id}, 100
  end

  test "Linear webhook routes by configured repository before dispatch" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
        repositories:
          - key: web
            repo: acme/web
            checkout_path: /srv/surfer/repos/web
            workflow: ./WEB_WORKFLOW.md
            linear_team_ids:
              - team-web
          - key: api
            repo: acme/api
            checkout_path: /srv/surfer/repos/api
            linear_team_ids:
              - team-api
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-route-1",
          issue: %{
            id: "issue-route-1",
            identifier: "WEB-1",
            title: "Fix",
            team: %{id: "team-web"},
            state: %{name: "Todo"}
          }
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(body, "secret"))
      |> post("/webhooks/linear/agent", body)

    assert json_response(conn, 202)["ok"] == true
    assert_receive {:dispatch, request}
    assert request.routing.repository_key == "web"
    assert request.routing.repository_full_name == "acme/web"
    assert request.routing.workflow_path == "./WEB_WORKFLOW.md"
    assert request.lineage.github.repo == "acme/web"
  end

  test "Linear webhook marks ambiguous repository routing as awaiting input without dispatch" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-linear-ambiguous-route-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
        repositories:
          - key: web
            repo: acme/web
          - key: api
            repo: acme/api
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-route-ambiguous",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-route-ambiguous",
          issue: %{id: "issue-route-ambiguous", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(body, "secret"))
      |> post("/webhooks/linear/agent", body)

    assert %{"ok" => true, "dispatched" => false, "routing_error" => routing_error, "run_id" => run_id} =
             json_response(conn, 202)

    assert routing_error =~ "ambiguous_repository"
    refute_receive {:unexpected_dispatch, _request}, 200

    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    assert run["status"] == "awaiting_input"
    assert run["error_code"] == "routing_failed"
    assert run["error_message"] =~ "ambiguous_repository"
  end

  test "Linear webhook updates agent session with Surfer run lookup URL before dispatch" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-linear-external-url-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        external_base_url: https://surfer.example.com
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn session_id, run_id ->
      send(parent, {:started, session_id, run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_external_urls_fun, fn session_id, urls ->
      send(parent, {:external_urls, session_id, urls})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-url-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-url-1",
          issue: %{id: "issue-url-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert %{"ok" => true, "run_id" => run_id} = json_response(conn, 202)
    assert_receive {:started, "session-url-1", ^run_id}

    assert_receive {:external_urls, "session-url-1", [%{label: "Surfer run", url: url}]}
    assert url == "https://surfer.example.com/api/v1/surfer/runs/#{run_id}"

    assert_receive {:dispatch, ^run_id}
  end

  test "Linear webhook accepts next rotation secret" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    previous_next_secret = System.get_env("LINEAR_WEBHOOK_SECRET_NEXT")

    on_exit(fn ->
      restore_env("LINEAR_WEBHOOK_SECRET", previous_secret)
      restore_env("LINEAR_WEBHOOK_SECRET_NEXT", previous_next_secret)
    end)

    System.put_env("LINEAR_WEBHOOK_SECRET", "current-secret")
    System.put_env("LINEAR_WEBHOOK_SECRET_NEXT", "next-secret")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
            webhook_secret_next: $LINEAR_WEBHOOK_SECRET_NEXT
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    body = linear_agent_body("webhook-rotation-1", "session-rotation-1", "issue-rotation-1")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(body, "next-secret"))
      |> post("/webhooks/linear/agent", body)

    assert %{"ok" => true, "run_id" => run_id} = json_response(conn, 202)
    assert_receive {:dispatch, ^run_id}, 1_000
  end

  test "Linear webhook records pending write when agent session external URL update fails" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-linear-external-url-fail-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        external_base_url: https://surfer.example.com
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :linear_external_url_failure_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :platform_write_failures],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    Application.put_env(:symphony_elixir, :surfer_linear_external_urls_fun, fn session_id, urls ->
      send(parent, {:external_urls_attempt, session_id, urls})
      {:error, :linear_5xx}
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-url-fail-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-url-fail-1",
          issue: %{id: "issue-url-fail-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert %{"ok" => true, "run_id" => run_id} = json_response(conn, 202)
    assert_receive {:external_urls_attempt, "session-url-fail-1", _urls}
    assert_receive {:dispatch, ^run_id}

    assert_eventually_pending_write(db_path, run_id, "session-url-fail-1:external_urls:#{run_id}")

    assert_receive {
      :telemetry,
      [:symphony, :surfer, :platform_write_failures],
      %{count: 1},
      metadata
    }

    assert metadata.run_id == run_id
    assert metadata.platform == "linear"
    assert metadata.external_id == "session-url-fail-1:external_urls:#{run_id}"
    assert metadata.reason == ":linear_5xx"
  end

  test "Linear webhook fails closed when enabled without webhook secret" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-1",
          issue: %{id: "issue-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "unused")
      |> post("/webhooks/linear/agent", body)

    assert json_response(conn, 503)["error"]["code"] == "missing_linear_webhook_secret"
  end

  test "Linear webhook emits signature failure telemetry without dispatching" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :linear_signature_failure}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :signature_failures],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-bad-signature",
          issue: %{id: "issue-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "bad")
      |> post("/webhooks/linear/agent", body)

    assert json_response(conn, 401)["error"]["code"] == "invalid_signature"
    assert_receive {:telemetry, [:symphony, :surfer, :signature_failures], %{count: 1}, linear_failure}
    assert linear_failure == %{platform: :linear, reason: :invalid_signature}
    refute_receive {:unexpected_dispatch, _run_id}, 100
  end

  test "Linear webhook returns 503 and emits ledger claim failure after bounded transient retry" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-claim-failed-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :ledger_claim_failed}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :ledger_claim_failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_run_claim_fun, fn _db_path, key, request, opts ->
      send(parent, {:claim_attempt, key, request.run_id, Keyword.fetch!(opts, :platform)})
      {:error, :sqlite_busy}
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    body = linear_agent_body("webhook-claim-failed", "session-claim-failed", "issue-claim-failed")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(body, "secret"))
      |> post("/webhooks/linear/agent", body)

    assert json_response(conn, 503)["error"]["code"] == "ledger_claim_failed"
    assert_receive {:claim_attempt, key, run_id, :linear}
    assert_receive {:claim_attempt, ^key, ^run_id, :linear}
    assert_receive {:claim_attempt, ^key, ^run_id, :linear}
    refute_receive {:claim_attempt, ^key, ^run_id, :linear}, 100
    refute_receive {:unexpected_dispatch, _run_id}, 100

    assert_receive {
      :telemetry,
      [:symphony, :surfer, :ledger_claim_failed],
      %{count: 1},
      metadata
    }

    assert metadata.run_id == run_id
    assert metadata.platform == :linear
    assert metadata.reason == ":sqlite_busy"
  end

  test "Linear webhook deduplicates source events before dispatch" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-webhook-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-1",
          issue: %{id: "issue-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    first =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    second =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert json_response(first, 202)["ok"] == true
    assert %{"duplicate" => true, "run_id" => duplicate_run_id} = json_response(second, 202)
    assert_receive {:dispatch, ^duplicate_run_id}, 1_000
    refute_receive {:dispatch, _other}, 200
  end

  test "Linear webhook blocks a second active run for the same agent session" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-linear-session-limit-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    created_body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-session-limit-created",
        type: "AgentSessionEvent",
        action: "created",
        agentSession: %{
          id: "session-limit-1",
          issue: %{id: "issue-session-limit-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    created_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(created_body, "secret"))
      |> post("/webhooks/linear/agent", created_body)

    assert %{"ok" => true, "run_id" => first_run_id} = json_response(created_conn, 202)
    assert_receive {:dispatch, ^first_run_id}, 1_000

    prompted_body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-session-limit-prompted",
        type: "AgentSessionEvent",
        action: "prompted",
        agentSession: %{
          id: "session-limit-1",
          agentActivity: %{id: "activity-session-limit-1"},
          issue: %{id: "issue-session-limit-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    prompted_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(prompted_body, "secret"))
      |> post("/webhooks/linear/agent", prompted_body)

    assert %{"ok" => true, "dispatched" => false, "linear_session_busy" => true, "run_id" => second_run_id} =
             json_response(prompted_conn, 202)

    refute_receive {:dispatch, ^second_run_id}, 200
    assert {:ok, %{"status" => "awaiting_input", "error_code" => "linear_session_active_run_limit"}} = RunLedger.get_run(db_path, second_run_id)
  end

  test "Linear webhook records cancelled run and skips dispatch while Surfer is paused" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    previous_token = System.get_env("LINEAR_ACCESS_TOKEN")

    on_exit(fn ->
      restore_env("LINEAR_WEBHOOK_SECRET", previous_secret)
      restore_env("LINEAR_ACCESS_TOKEN", previous_token)
    end)

    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")
    System.put_env("LINEAR_ACCESS_TOKEN", "linear-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-paused-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        paused: true
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
            access_token: $LINEAR_ACCESS_TOKEN
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity, session_id, type, body})
      {:error, :linear_down}
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-1",
          issue: %{id: "issue-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert %{"ok" => true, "paused" => true, "run_id" => run_id} = json_response(conn, 202)
    refute_receive {:dispatch, _run_id}, 200
    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    assert run["linear_agent_session_id"] == "session-1"
    assert_eventually_pending_write(db_path, run_id, "session-1:error:#{run_id}")
    assert_receive {:linear_activity, "session-1", :error, body}, 1_000
    assert body =~ "surfer_paused"
    assert run["status"] == "cancelled"
  end

  test "Discord webhook rejects messages from unconfigured guilds" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            allowed_guilds:
              - guild-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    conn =
      post(build_conn(), "/webhooks/discord/message", %{
        "id" => "message-1",
        "guild_id" => "guild-2",
        "channel_id" => "channel-1",
        "content" => "surfer question"
      })

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "unauthorized_guild", "message" => "Discord guild is not allowed"}
           }
  end

  test "Discord webhook rejects messages from unconfigured channels" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-allowed
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    conn =
      post(build_conn(), "/webhooks/discord/message", %{
        "id" => "message-channel-denied",
        "guild_id" => "guild-1",
        "channel_id" => "channel-denied",
        "content" => "surfer question"
      })

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "unauthorized_channel", "message" => "Discord channel is not allowed"}
           }

    refute_receive {:unexpected_dispatch, _run_id}, 100
  end

  test "Discord message ingress uses the configured message path only" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            message_ingress_path: /internal/surfer/discord/message
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    custom_conn =
      post(build_conn(), "/internal/surfer/discord/message", %{
        "id" => "message-custom-path-1",
        "guild_id" => "guild-1",
        "channel_id" => "channel-1",
        "content" => "surfer question"
      })

    assert %{"ok" => true, "run_id" => run_id} = json_response(custom_conn, 202)
    assert_receive {:discord_dispatch, ^run_id}

    default_conn =
      post(build_conn(), "/webhooks/discord/message", %{
        "id" => "message-default-path-denied",
        "guild_id" => "guild-1",
        "channel_id" => "channel-1",
        "content" => "surfer question"
      })

    assert json_response(default_conn, 404) == %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
    refute_receive {:discord_dispatch, _run_id}, 100
  end

  test "Discord interactions use the configured interactions path only" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            interactions_path: /internal/surfer/discord/interactions
            public_key: $DISCORD_PUBLIC_KEY
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    body = Jason.encode!(%{type: 1})

    custom_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(body, private_key)
      |> post("/internal/surfer/discord/interactions", body)

    assert json_response(custom_conn, 200) == %{"type" => 1}

    default_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(body, private_key)
      |> post("/webhooks/discord/interactions", body)

    assert json_response(default_conn, 404) == %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
  end

  test "GitHub webhook-looking paths are not platform ingress in V0.1" do
    previous_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    System.put_env("GITHUB_TOKEN", "github-token-secret")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          github:
            enabled: true
            token: $GITHUB_TOKEN
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_linear_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_discord_dispatch, request.run_id})
      :ok
    end)

    conn =
      post(build_conn(), "/webhooks/github", %{
        "action" => "opened",
        "repository" => %{"full_name" => "acme/web"}
      })

    assert json_response(conn, 404) == %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
    refute_receive {:unexpected_linear_dispatch, _run_id}, 100
    refute_receive {:unexpected_discord_dispatch, _run_id}, 100
  end

  test "Discord interactions verify signatures, answer ping, and defer slash command dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request})
      :ok
    end)

    ping_body = Jason.encode!(%{type: 1})

    ping =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(ping_body, private_key)
      |> post("/webhooks/discord/interactions", ping_body)

    assert json_response(ping, 200) == %{"type" => 1}

    command_body =
      Jason.encode!(%{
        id: "interaction-1",
        application_id: "app-1",
        token: "token-1",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]
        }
      })

    command =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(command, 200)["type"] == 5
    assert_receive {:discord_dispatch, request}
    assert request.source.trigger_type == :slash_command
    assert request.request.mode == :code_question
  end

  test "Discord async fallback writes pending events to the ingress ledger after workflow reload" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-ingress-ledger-#{System.unique_integer([:positive])}.sqlite3")
    next_db_path = Path.join(System.tmp_dir!(), "surfer-discord-next-ledger-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    File.rm_rf(next_db_path)

    on_exit(fn ->
      File.rm_rf(db_path)
      File.rm_rf(next_db_path)
    end)

    write_discord_workflow!(db_path)
    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(next_db_path)

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch_blocked, self(), request.run_id})

      receive do
        :release_discord_dispatch -> :ok
      after
        1_000 -> {:error, :dispatch_timeout}
      end
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn _application_id, _token, _body ->
      {:error, :interaction_down}
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-ledger-capture",
        application_id: "app-1",
        token: "token-1",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "prompt", type: 3, value: "record this in the ingress ledger"}]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch_blocked, task_pid, run_id}

    write_discord_workflow!(next_db_path)
    WorkflowStore.force_reload()
    send(task_pid, :release_discord_dispatch)

    assert_eventually_pending_write(db_path, run_id, "channel-1:interaction_fallback:#{run_id}")
    assert {:ok, []} = RunLedger.list_pending_writes(next_db_path)
  end

  test "Discord interaction routes by configured repository before dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-route-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
        repositories:
          - key: web
            repo: acme/web
            checkout_path: /srv/surfer/repos/web
            workflow: ./WEB_WORKFLOW.md
            discord_channel_ids:
              - channel-web
          - key: api
            repo: acme/api
            discord_channel_ids:
              - channel-api
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-route-1",
        application_id: "app-1",
        token: "route-token",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-web",
        member: %{user: %{id: "route-user-1"}},
        data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch, request}
    assert request.routing.repository_key == "web"
    assert request.routing.repository_full_name == "acme/web"
    assert request.routing.workflow_path == "./WEB_WORKFLOW.md"
    assert request.lineage.github.repo == "acme/web"

    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["payload_json"] =~ "acme/web"
    refute run["payload_json"] =~ "route-token"
  end

  test "Discord interaction marks ambiguous repository routing as awaiting input without dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-ambiguous-route-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
        repositories:
          - key: web
            repo: acme/web
          - key: api
            repo: acme/api
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn _application_id, _token, body ->
      send(parent, {:interaction_response, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-route-ambiguous",
        application_id: "app-1",
        token: "ambiguous-token",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-unknown",
        member: %{user: %{id: "ambiguous-route-user-1"}},
        data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:interaction_response, body}
    assert body =~ "ambiguous repository"
    assert body =~ "web"
    assert body =~ "api"
    refute_receive {:unexpected_dispatch, _request}, 200

    assert {:ok, run_id} = RunLedger.lookup_idempotency_key(db_path, "discord_interaction:interaction-route-ambiguous:code_question")
    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    assert run["status"] == "awaiting_input"
    assert run["error_code"] == "routing_failed"
    assert run["error_message"] =~ "ambiguous_repository"
    refute run["payload_json"] =~ "ambiguous-token"
  end

  test "Discord interaction accepts next rotation public key" do
    {current_public_key, _current_private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {next_public_key, next_private_key} = :crypto.generate_key(:eddsa, :ed25519)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            public_key: #{Base.encode16(current_public_key, case: :lower)}
            public_key_next: #{Base.encode16(next_public_key, case: :lower)}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-rotation-1",
        application_id: "app-1",
        token: "interaction-token-rotation",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        data: %{
          name: "surfer",
          options: [
            %{"name" => "ask", "type" => 1, "options" => [%{"name" => "prompt", "value" => "Where is routing handled?"}]}
          ]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, next_private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch, _run_id}, 1_000
  end

  test "Discord interaction deduplicates before dispatch and edits original response without storing token" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-dedup-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn application_id, token, body ->
      send(parent, {:interaction_response, application_id, token, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-dedup-1",
        application_id: "app-1",
        token: "token-secret",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "dedup-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]
        }
      })

    first =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    second =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(first, 200)["type"] == 5
    assert json_response(second, 200)["type"] == 5
    assert_receive {:discord_dispatch, run_id}
    refute_receive {:discord_dispatch, _other}, 200
    assert_receive {:interaction_response, "app-1", "token-secret", body}
    assert body =~ run_id

    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    refute run["payload_json"] =~ "token-secret"
  end

  test "Discord interaction response failure emits telemetry and falls back to channel message without storing token" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-followup-fail-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :discord_followup_failed}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :discord_followup_failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn application_id, token, body ->
      send(parent, {:interaction_response_attempt, application_id, token, body})
      {:error, :discord_5xx}
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      send(parent, {:channel_fallback, channel_id, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-followup-fail-1",
        application_id: "app-1",
        token: "interaction-token-secret",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "followup-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch, run_id}
    assert_receive {:interaction_response_attempt, "app-1", "interaction-token-secret", body}
    assert_receive {:channel_fallback, "channel-1", ^body}

    metadata = assert_discord_followup_failed_for("interaction-followup-fail-1")

    assert metadata.application_id == "app-1"
    assert metadata.interaction_id == "interaction-followup-fail-1"
    assert metadata.channel_id == "channel-1"
    assert metadata.reason == ":discord_5xx"
    refute inspect(metadata) =~ "interaction-token-secret"

    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    refute run["payload_json"] =~ "interaction-token-secret"
  end

  test "Discord interaction response retries transient edit failure before channel fallback" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-followup-retry-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, target_body} = Agent.start_link(fn -> nil end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_retry_backoff_ms, 0)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn application_id, token, body ->
      if token == "interaction-token-secret" do
        attempt =
          Agent.get_and_update(attempts, fn count ->
            next_count = count + 1
            {next_count, next_count}
          end)

        send(parent, {:interaction_response_attempt, attempt, application_id, token, body})
        Agent.update(target_body, fn _current_body -> body end)

        if attempt == 1 do
          {:error, :discord_5xx}
        else
          :ok
        end
      else
        :ok
      end
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      if body == Agent.get(target_body, & &1) do
        send(parent, {:channel_fallback, channel_id, body})
      end

      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-followup-retry-1",
        application_id: "app-1",
        token: "interaction-token-secret",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "followup-retry-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch, run_id}
    assert_receive {:interaction_response_attempt, 1, "app-1", "interaction-token-secret", body}
    assert_receive {:interaction_response_attempt, 2, "app-1", "interaction-token-secret", ^body}
    refute_receive {:channel_fallback, _channel_id, _body}, 100

    assert {:ok, run} = RunLedger.get_run(db_path, run_id)
    refute run["payload_json"] =~ "interaction-token-secret"
  end

  test "Discord interaction fallback channel failure queues pending write without storing token" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-fallback-pending-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :discord_fallback_pending_write}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :discord_followup_failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn application_id, token, body ->
      send(parent, {:interaction_response_attempt, application_id, token, body})

      {:error, {:discord_5xx, "url=https://discord.com/api/v10/webhooks/#{application_id}/#{token}/messages/@original"}}
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      send(parent, {:channel_fallback_attempt, channel_id, body})
      {:error, {:channel_down, "Authorization: Bot bot-token"}}
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-fallback-pending-1",
        application_id: "app-1",
        token: "interaction-token-secret",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "fallback-pending-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]
        }
      })

    run_id_ref = make_ref()

    log =
      capture_log(fn ->
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_discord_signature_headers(command_body, private_key)
          |> post("/webhooks/discord/interactions", command_body)

        assert json_response(conn, 200)["type"] == 5
        assert_receive {:discord_dispatch, run_id}
        send(parent, {run_id_ref, run_id})
        assert_receive {:interaction_response_attempt, "app-1", "interaction-token-secret", body}
        assert_receive {:channel_fallback_attempt, "channel-1", ^body}

        metadata = assert_discord_followup_failed_for("interaction-fallback-pending-1")
        assert metadata.reason =~ "[REDACTED]"
        refute metadata.reason =~ "interaction-token-secret"

        external_id = "channel-1:interaction_fallback:#{run_id}"
        assert_eventually_pending_write(db_path, run_id, external_id)

        assert {:ok, events} = RunLedger.list_events(db_path, run_id)

        pending =
          Enum.find(events, &(&1["event_type"] == "pending_write" and &1["external_id"] == external_id))

        assert pending["platform"] == "discord"
        assert pending["payload_json"] =~ "channel_message"
        assert pending["payload_json"] =~ "channel-1"
        refute pending["payload_json"] =~ "interaction-token-secret"
        refute pending["payload_json"] =~ "bot-token"
        refute Enum.any?(events, &(inspect(&1) =~ "interaction-token-secret"))
        refute Enum.any?(events, &(inspect(&1) =~ "bot-token"))
      end)

    assert_receive {^run_id_ref, run_id}
    assert log =~ "Discord interaction response failed"
    assert log =~ "Discord interaction fallback channel post failed"
    assert log =~ "run_id=#{run_id}"
    refute log =~ "interaction-token-secret"
    refute log =~ "bot-token"
  end

  test "Discord dispatch error channel notification failure queues pending write without storing token" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-error-pending-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      {:error, :runner_down}
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      if body == "Surfer request failed: :runner_down" do
        send(parent, {:discord_error_notification_attempt, channel_id, body})
        {:error, :discord_down}
      else
        :ok
      end
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-error-pending-1",
        application_id: "app-1",
        token: "interaction-token-secret",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "error-pending-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "where is routing handled?"}]}]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:discord_dispatch, run_id}
    assert_receive {:discord_error_notification_attempt, "channel-1", body}
    assert body == "Surfer request failed: :runner_down"

    external_id = "channel-1:error:#{run_id}"
    assert_eventually_pending_write(db_path, run_id, external_id)

    assert {:ok, events} = RunLedger.list_events(db_path, run_id)

    pending =
      Enum.find(events, &(&1["event_type"] == "pending_write" and &1["external_id"] == external_id))

    assert pending["platform"] == "discord"
    assert pending["payload_json"] =~ "channel_message"
    assert pending["payload_json"] =~ "runner_down"
    refute Enum.any?(events, &(inspect(&1) =~ "interaction-token-secret"))
  end

  test "Discord interaction applies per-user cooldown before dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_bot_token = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      restore_env("DISCORD_PUBLIC_KEY", previous_public_key)
      restore_env("DISCORD_BOT_TOKEN", previous_bot_token)
    end)

    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            bot_token: $DISCORD_BOT_TOKEN
            per_user_cooldown_seconds: 30
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request.run_id})
      :ok
    end)

    command = fn id ->
      Jason.encode!(%{
        id: id,
        application_id: "app-1",
        token: "token-#{id}",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "cooldown-user-1"}},
        data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "question #{id}"}]}]}
      })
    end

    first_body = command.("interaction-cooldown-1")
    second_body = command.("interaction-cooldown-2")

    first =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(first_body, private_key)
      |> post("/webhooks/discord/interactions", first_body)

    second =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(second_body, private_key)
      |> post("/webhooks/discord/interactions", second_body)

    assert json_response(first, 200)["type"] == 5
    assert %{"type" => 4, "data" => %{"content" => content}} = json_response(second, 200)
    assert content =~ "rate limit"
    assert_receive {:discord_dispatch, _run_id}
    refute_receive {:discord_dispatch, _other}, 200
  end

  test "Discord interaction applies per-channel queued run limit before dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")

    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-channel-limit-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            per_channel_queued_limit: 3
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(db_path)

    for id <- 1..3 do
      assert {:ok, request} =
               RunRequest.from_discord_message(%{
                 "id" => "queued-message-#{id}",
                 "guild_id" => "guild-1",
                 "channel_id" => "channel-1",
                 "content" => "surfer queued #{id}"
               })

      assert {:ok, %{status: :claimed}} =
               RunLedger.claim_run(db_path, "queued-message-#{id}", request, platform: :discord)
    end

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-channel-limit-4",
        application_id: "app-1",
        token: "token-channel-limit",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "channel-limit-user-4"}},
        data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "question 4"}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert %{"type" => 4, "data" => %{"content" => content}} = json_response(conn, 200)
    assert content =~ "rate limit"
    refute_receive {:unexpected_dispatch, _run_id}, 200

    assert {:ok, limited_run_id} =
             RunLedger.lookup_idempotency_key(db_path, "discord_interaction:interaction-channel-limit-4:code_question")

    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, limited_run_id)
  end

  test "Discord interaction applies daily per-user run limit before dispatch" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")

    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-daily-user-limit-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            per_user_daily_run_limit: 2
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(db_path)

    for id <- 1..2 do
      assert {:ok, request} =
               RunRequest.from_discord_message(%{
                 "id" => "daily-user-message-#{id}",
                 "guild_id" => "guild-1",
                 "channel_id" => "channel-1",
                 "author" => %{"id" => "daily-user-1"},
                 "content" => "surfer previous #{id}"
               })

      assert {:ok, %{status: :claimed}} =
               RunLedger.claim_run(db_path, "daily-user-message-#{id}", request, platform: :discord)
    end

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-daily-user-limit-3",
        application_id: "app-1",
        token: "token-daily-user-limit",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "daily-user-1"}},
        data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "question 3"}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert %{"type" => 4, "data" => %{"content" => content}} = json_response(conn, 200)
    assert content =~ "rate limit"
    refute_receive {:unexpected_dispatch, _run_id}, 200

    assert {:ok, limited_run_id} =
             RunLedger.lookup_idempotency_key(db_path, "discord_interaction:interaction-daily-user-limit-3:code_question")

    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, limited_run_id)
  end

  test "Discord interaction webhook fails closed when enabled without public key" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-timestamp", Integer.to_string(System.system_time(:second)))
      |> put_req_header("x-signature-ed25519", String.duplicate("0", 128))
      |> post("/webhooks/discord/interactions", Jason.encode!(%{type: 1}))

    assert json_response(conn, 503)["error"]["code"] == "missing_discord_public_key"
  end

  test "Discord interaction emits signature failure telemetry without dispatching" do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()
    handler_id = {__MODULE__, self(), :discord_signature_failure}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :signature_failures],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    body = Jason.encode!(%{type: 1})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-timestamp", Integer.to_string(System.system_time(:second)))
      |> put_req_header("x-signature-ed25519", String.duplicate("0", 128))
      |> post("/webhooks/discord/interactions", body)

    assert json_response(conn, 401)["error"]["code"] == "invalid_signature"
    assert_receive {:telemetry, [:symphony, :surfer, :signature_failures], %{count: 1}, discord_failure}
    assert discord_failure == %{platform: :discord, reason: :invalid_signature}
    refute_receive {:unexpected_dispatch, _run_id}, 100
  end

  test "Discord interaction rejects signatures outside configured replay window" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            signature_max_age_seconds: 1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    body = Jason.encode!(%{id: "interaction-stale-1", type: 2, data: %{name: "surfer", options: [%{name: "ask", type: 1, options: [%{name: "prompt", type: 3, value: "question"}]}]}})
    stale_timestamp = Integer.to_string(System.system_time(:second) - 2)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(body, private_key, stale_timestamp)
      |> post("/webhooks/discord/interactions", body)

    assert json_response(conn, 401)["error"]["code"] == "stale_timestamp"
    refute_receive {:unexpected_dispatch, _run_id}, 100
  end

  test "Discord issue creation creates Linear issue then posts a Discord notification" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
            allowed_guilds:
              - guild-1
          linear:
            enabled: true
            team_id: team-1
            project_id: project-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_issue_create_fun, fn attrs ->
      send(parent, {:issue_attrs, attrs})
      {:ok, %{id: "issue-1", identifier: "SURF-1", url: "https://linear.app/acme/issue/SURF-1/test"}}
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      send(parent, {:discord_post, channel_id, body})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    conn =
      post(build_conn(), "/webhooks/discord/message", %{
        "id" => "message-1",
        "guild_id" => "guild-1",
        "channel_id" => "channel-1",
        "content" => "surfer create issue: Fix routing"
      })

    assert json_response(conn, 202)["mode"] == "issue_create"
    assert_receive {:issue_attrs, attrs}
    assert attrs.title == "Fix routing"
    assert_receive {:discord_post, "channel-1", body}
    assert body =~ "SURF-1"
    refute_receive {:unexpected_dispatch, _run_id}, 100
  end

  test "Discord run command creates a Linear issue before dispatching durable work" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")

    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-run-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
          linear:
            enabled: true
            team_id: team-1
            project_id: project-1
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_issue_create_fun, fn attrs ->
      send(parent, {:issue_attrs, attrs})
      {:ok, %{id: "issue-run-1", identifier: "SURF-2", title: attrs.title, url: "https://linear.app/acme/issue/SURF-2/run"}}
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      send(parent, {:discord_post, channel_id, body})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:discord_dispatch, request})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn _application_id, _token, body ->
      send(parent, {:interaction_response, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-run-1",
        application_id: "app-1",
        token: "run-token",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "run-user-1"}},
        data: %{
          name: "surfer",
          options: [%{name: "run", type: 1, options: [%{name: "prompt", type: 3, value: "Implement routing"}]}]
        }
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:issue_attrs, attrs}
    assert attrs.title == "Implement routing"
    assert attrs.description =~ "Discord message interaction-run-1"
    issue_message = assert_discord_post_contains("channel-1", "SURF-2")
    assert issue_message =~ "SURF-2"
    assert_receive {:discord_dispatch, request}
    assert request.request.mode == :durable_task
    assert request.lineage.linear.issue_id == "issue-run-1"
    assert request.lineage.linear.issue_identifier == "SURF-2"
    assert request.issue.identifier == "SURF-2"
    assert_receive {:interaction_response, accepted}
    assert accepted =~ request.run_id

    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["canonical_linear_issue_id"] == "issue-run-1"
    assert {:ok, links} = RunLedger.list_links(db_path, request.run_id)
    assert Enum.any?(links, &(&1["platform"] == "linear" and &1["kind"] == "issue" and &1["external_id"] == "issue-run-1"))
    refute run["payload_json"] =~ "run-token"
  end

  test "Discord cancel command applies lifecycle control without dispatching new work" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")

    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-cancel-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert :ok = RunLedger.initialize(db_path)
    target_run_id = "surf_run_cancel_target"

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-cancel-target",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    request = %{request | run_id: target_run_id}
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "target-key", request, platform: :discord)
    assert :ok = RunLedger.update_status(db_path, target_run_id, "running")

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn _application_id, _token, body ->
      send(parent, {:interaction_response, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-cancel-1",
        application_id: "app-1",
        token: "cancel-token",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "cancel-user-1"}},
        data: %{name: "surfer", options: [%{name: "cancel", type: 1, options: [%{name: "run_id", type: 3, value: target_run_id}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:interaction_response, body}
    assert body =~ "cancelled"
    refute_receive {:unexpected_dispatch, _run_id}, 200
    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, target_run_id)
    assert {:ok, command_run_id} = RunLedger.lookup_idempotency_key(db_path, "discord_interaction:interaction-cancel-1:lifecycle_control")
    assert_eventually_run_status(db_path, command_run_id, "completed")
  end

  test "Discord retry command creates a linked retry run without dispatching new work" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous_public_key = System.get_env("DISCORD_PUBLIC_KEY")

    on_exit(fn -> restore_env("DISCORD_PUBLIC_KEY", previous_public_key) end)
    System.put_env("DISCORD_PUBLIC_KEY", Base.encode16(public_key, case: :lower))

    db_path = Path.join(System.tmp_dir!(), "surfer-discord-retry-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert :ok = RunLedger.initialize(db_path)
    target_run_id = "surf_run_retry_target"

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-retry-target",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    request = %{request | run_id: target_run_id}
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "retry-target-key", request, platform: :discord)
    assert :ok = RunLedger.update_status(db_path, target_run_id, "running")
    assert :ok = RunLedger.update_status(db_path, target_run_id, "failed", reason: "runner crashed")

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_discord_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_discord_interaction_response_fun, fn _application_id, _token, body ->
      send(parent, {:interaction_response, body})
      :ok
    end)

    command_body =
      Jason.encode!(%{
        id: "interaction-retry-1",
        application_id: "app-1",
        token: "retry-token",
        type: 2,
        guild_id: "guild-1",
        channel_id: "channel-1",
        member: %{user: %{id: "retry-user-1"}},
        data: %{name: "surfer", options: [%{name: "retry", type: 1, options: [%{name: "run_id", type: 3, value: target_run_id}]}]}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_discord_signature_headers(command_body, private_key)
      |> post("/webhooks/discord/interactions", command_body)

    assert json_response(conn, 200)["type"] == 5
    assert_receive {:interaction_response, body}
    assert body =~ "created for #{target_run_id}"
    [retry_run_id] = Regex.run(~r/surf_run_retry_[A-Za-z0-9_-]+/, body)
    refute_receive {:unexpected_dispatch, _run_id}, 200
    assert {:ok, %{"status" => "queued"}} = RunLedger.get_run(db_path, retry_run_id)
    assert {:ok, links} = RunLedger.list_links(db_path, retry_run_id)
    assert Enum.any?(links, &(&1["kind"] == "retry_of" and &1["external_id"] == target_run_id))
    assert {:ok, command_run_id} = RunLedger.lookup_idempotency_key(db_path, "discord_interaction:interaction-retry-1:lifecycle_control")
    assert_eventually_run_status(db_path, command_run_id, "completed")
  end

  test "Linear ingress marks a run failed when the daily budget cap is exhausted" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")

    on_exit(fn ->
      restore_env("LINEAR_WEBHOOK_SECRET", previous_secret)
    end)

    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-budget-cap-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        codex:
          daily_budget_usd: 1.0
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, spent_request} =
             RunRequest.from_discord_message(%{
               "id" => "message-budget-spent",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "budget-spent", spent_request)
    assert :ok = Budget.record_usage(db_path, spent_request.run_id, 1.25)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-budget-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-budget-1",
          issue: %{id: "issue-budget-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert %{"budget_cap" => true, "run_id" => run_id} = json_response(conn, 202)
    refute_receive {:unexpected_dispatch, _run_id}, 200
    assert {:ok, %{"status" => "failed", "error_code" => "budget_cap"}} = RunLedger.get_run(db_path, run_id)
  end

  test "operator run lookup is loopback-only and redacts stored payloads" do
    db_path = Path.join(System.tmp_dir!(), "surfer-operator-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-operator-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "operator-key", request, platform: :discord)

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "test_event",
               payload: %{discord_interaction_token: "secret-token"}
             })

    local =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> get("/api/v1/surfer/runs/#{request.run_id}")

    assert %{"run" => %{"id" => run_id}, "events" => events} = json_response(local, 200)
    assert run_id == request.run_id
    encoded = Jason.encode!(events)
    refute encoded =~ "secret-token"
    assert encoded =~ "[REDACTED]"

    remote =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> get("/api/v1/surfer/runs/#{request.run_id}")

    assert json_response(remote, 403)["error"]["code"] == "operator_lookup_forbidden"
  end

  test "operator can requeue pending writes only from loopback" do
    db_path = Path.join(System.tmp_dir!(), "surfer-operator-requeue-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "agentSession" => %{
                 "id" => "session-requeue-1",
                 "issue" => %{"id" => "issue-requeue-1", "identifier" => "ENG-1", "title" => "Fix"}
               }
             })

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "operator-requeue-key", request, platform: :linear)

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-requeue-1:response",
               idempotency_hash: "hash-response",
               payload: %{session_id: "session-requeue-1", type: "response", body: "Surfer completed."}
             })

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_pending_write_retry_fun, fn write ->
      send(parent, {:retry_pending_write, write["external_id"], write["idempotency_hash"]})
      {:ok, %{status: "resent"}}
    end)

    local =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/outbox/requeue", %{})

    assert %{"attempted" => 1, "drained" => 1, "failed" => 0} = json_response(local, 200)
    assert_receive {:retry_pending_write, "session-requeue-1:response", "hash-response"}
    assert {:ok, []} = RunLedger.list_pending_writes(db_path)

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write_drained"))

    remote =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> post("/api/v1/surfer/outbox/requeue", %{})

    assert json_response(remote, 403)["error"]["code"] == "operator_control_forbidden"
  end

  test "operator can create a ledger backup only from loopback" do
    state_dir = Path.join(System.tmp_dir!(), "surfer-operator-backup-#{System.unique_integer([:positive])}")
    db_path = Path.join(state_dir, "surfer.sqlite3")
    File.rm_rf(state_dir)
    on_exit(fn -> File.rm_rf(state_dir) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-backup-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "operator-backup-key", request, platform: :discord)

    local =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/ledger/backup", %{"label" => "manual-1"})

    assert %{
             "path" => backup_path,
             "integrity" => "ok",
             "table_count" => table_count,
             "size_bytes" => size_bytes
           } = json_response(local, 200)

    assert table_count >= 4
    assert size_bytes > 0
    assert Path.dirname(backup_path) == Path.join(state_dir, "backups")
    assert {:ok, %{"status" => "queued"}} = RunLedger.get_run(backup_path, request.run_id)

    remote =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> post("/api/v1/surfer/ledger/backup", %{"label" => "manual-2"})

    assert json_response(remote, 403)["error"]["code"] == "operator_control_forbidden"
    refute File.exists?(Path.join([state_dir, "backups", "surfer-ledger-manual-2.sqlite3"]))
  end

  test "operator lifecycle controls are loopback-only and mutate the ledger" do
    db_path = Path.join(System.tmp_dir!(), "surfer-operator-controls-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(db_path)

    cancel_request = claimed_operator_control_request!(db_path, "cancel")
    assert :ok = RunLedger.update_status(db_path, cancel_request.run_id, "running")

    cancel =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/runs/#{cancel_request.run_id}/cancel", %{})

    assert %{"run_id" => run_id, "status" => "cancelled"} = json_response(cancel, 200)
    assert run_id == cancel_request.run_id
    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, cancel_request.run_id)

    takeover_request = claimed_operator_control_request!(db_path, "takeover")
    assert :ok = RunLedger.update_status(db_path, takeover_request.run_id, "running")

    takeover =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/runs/#{takeover_request.run_id}/takeover", %{})

    assert %{"run_id" => run_id, "status" => "awaiting_review"} = json_response(takeover, 200)
    assert run_id == takeover_request.run_id
    assert {:ok, %{"status" => "awaiting_review"}} = RunLedger.get_run(db_path, takeover_request.run_id)

    failed_request = claimed_operator_control_request!(db_path, "retry")
    assert :ok = RunLedger.update_status(db_path, failed_request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, failed_request.run_id, "failed", error_message: "boom")

    retry =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/runs/#{failed_request.run_id}/retry", %{"nonce" => "n1"})

    assert %{"run_id" => retry_run_id, "previous_run_id" => previous_run_id} = json_response(retry, 200)
    assert previous_run_id == failed_request.run_id
    assert retry_run_id != failed_request.run_id
    assert {:ok, %{"status" => "queued"}} = RunLedger.get_run(db_path, retry_run_id)
    assert {:ok, links} = RunLedger.list_links(db_path, retry_run_id)
    assert Enum.any?(links, &(&1["kind"] == "retry_of" and &1["external_id"] == failed_request.run_id))

    remote =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> post("/api/v1/surfer/runs/#{retry_run_id}/cancel", %{})

    assert json_response(remote, 403)["error"]["code"] == "operator_control_forbidden"
  end

  test "operator cancel stops an active direct-dispatch run" do
    db_path = Path.join(System.tmp_dir!(), "surfer-operator-active-cancel-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(db_path)

    previous_orchestrator_server = Application.get_env(:symphony_elixir, :surfer_orchestrator_server)
    on_exit(fn -> restore_app_env(:surfer_orchestrator_server, previous_orchestrator_server) end)

    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :OperatorActiveCancelOrchestrator)
    Application.put_env(:symphony_elixir, :surfer_orchestrator_server, orchestrator_name)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
    end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-operator-cancel-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "where is routing handled?"
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:operator_cancel_runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:operator_cancel_runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)

    cancel =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/runs/#{request.run_id}/cancel", %{})

    assert %{"run_id" => run_id, "status" => "cancelled"} = json_response(cancel, 200)
    assert run_id == request.run_id
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, request.run_id)
  end

  test "operator takeover stops an active direct-dispatch run and leaves handoff state" do
    db_path = Path.join(System.tmp_dir!(), "surfer-operator-active-takeover-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    assert :ok = RunLedger.initialize(db_path)

    previous_orchestrator_server = Application.get_env(:symphony_elixir, :surfer_orchestrator_server)
    on_exit(fn -> restore_app_env(:surfer_orchestrator_server, previous_orchestrator_server) end)

    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :OperatorActiveTakeoverOrchestrator)
    Application.put_env(:symphony_elixir, :surfer_orchestrator_server, orchestrator_name)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
    end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-operator-takeover-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "where is routing handled?"
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:operator_takeover_runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:operator_takeover_runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)

    takeover =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/runs/#{request.run_id}/takeover", %{})

    assert %{"run_id" => run_id, "status" => "awaiting_review"} = json_response(takeover, 200)
    assert run_id == request.run_id
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert {:ok, %{"status" => "awaiting_review"}} = RunLedger.get_run(db_path, request.run_id)
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "handoff_note" and &1["payload_json"] =~ "operator:http"))
  end

  test "operator pause and unpause control ingress dispatch" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    previous_token = System.get_env("LINEAR_ACCESS_TOKEN")

    on_exit(fn ->
      restore_env("LINEAR_WEBHOOK_SECRET", previous_secret)
      restore_env("LINEAR_ACCESS_TOKEN", previous_token)
    end)

    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")
    System.put_env("LINEAR_ACCESS_TOKEN", "linear-token")

    db_path = Path.join(System.tmp_dir!(), "surfer-operator-pause-#{System.unique_integer([:positive])}.sqlite3")
    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
            access_token: $LINEAR_ACCESS_TOKEN
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:dispatch, request.run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn _session_id, _run_id -> :ok end)

    pause =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/pause", %{"reason" => "maintenance"})

    assert %{"paused" => true, "runtime_paused" => true, "reason" => "maintenance"} = json_response(pause, 200)

    paused_body =
      linear_agent_body("webhook-runtime-pause-1", "session-runtime-pause-1", "issue-runtime-pause-1")

    paused_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(paused_body, "secret"))
      |> post("/webhooks/linear/agent", paused_body)

    assert %{"ok" => true, "paused" => true, "run_id" => paused_run_id} = json_response(paused_conn, 202)
    refute_receive {:dispatch, _run_id}, 200
    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, paused_run_id)

    unpause =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/v1/surfer/unpause", %{})

    assert %{"paused" => false, "runtime_paused" => false} = json_response(unpause, 200)

    unpaused_body =
      linear_agent_body("webhook-runtime-pause-2", "session-runtime-pause-2", "issue-runtime-pause-2")

    unpaused_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", linear_signature(unpaused_body, "secret"))
      |> post("/webhooks/linear/agent", unpaused_body)

    assert %{"ok" => true, "run_id" => unpaused_run_id} = json_response(unpaused_conn, 202)
    assert_receive {:dispatch, ^unpaused_run_id}, 1_000

    remote =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> post("/api/v1/surfer/pause", %{})

    assert json_response(remote, 403)["error"]["code"] == "operator_control_forbidden"
  end

  test "Linear ingress marks a run failed when workspace disk pressure is above the configured threshold" do
    previous_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    on_exit(fn -> restore_env("LINEAR_WEBHOOK_SECRET", previous_secret) end)
    System.put_env("LINEAR_WEBHOOK_SECRET", "secret")

    db_path = Path.join(System.tmp_dir!(), "surfer-disk-pressure-#{System.unique_integer([:positive])}.sqlite3")
    workspace_root = Path.join(System.tmp_dir!(), "surfer-disk-workspaces-#{System.unique_integer([:positive])}")

    File.rm_rf(db_path)
    File.rm_rf(workspace_root)

    on_exit(fn ->
      File.rm_rf(db_path)
      File.rm_rf(workspace_root)
    end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      workspace:
        root: #{workspace_root}
      surfer:
        storage:
          sqlite_path: #{db_path}
          disk_pressure_max_used_percent: 90
        platforms:
          linear:
            enabled: true
            webhook_secret: $LINEAR_WEBHOOK_SECRET
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    Application.put_env(:symphony_elixir, :surfer_disk_usage_fun, fn ^workspace_root ->
      {:ok, %{used_percent: 91}}
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_dispatch_fun, fn request ->
      send(parent, {:unexpected_dispatch, request.run_id})
      :ok
    end)

    body =
      Jason.encode!(%{
        webhookTimestamp: System.system_time(:millisecond),
        webhookId: "webhook-disk-1",
        type: "AgentSessionEvent",
        agentSession: %{
          id: "session-disk-1",
          issue: %{id: "issue-disk-1", identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
        }
      })

    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post("/webhooks/linear/agent", body)

    assert %{"disk_pressure" => true, "run_id" => run_id} = json_response(conn, 202)
    refute_receive {:unexpected_dispatch, _run_id}, 200
    assert {:ok, %{"status" => "failed", "error_code" => "disk_pressure"}} = RunLedger.get_run(db_path, run_id)
  end

  defp put_discord_signature_headers(conn, body, private_key, timestamp \\ Integer.to_string(System.system_time(:second))) do
    signature =
      :crypto.sign(:eddsa, :none, timestamp <> body, [private_key, :ed25519])
      |> Base.encode16(case: :lower)

    conn
    |> put_req_header("x-signature-timestamp", timestamp)
    |> put_req_header("x-signature-ed25519", signature)
  end

  defp write_discord_workflow!(db_path) do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          sqlite_path: #{db_path}
        platforms:
          discord:
            enabled: true
            public_key: $DISCORD_PUBLIC_KEY
            allowed_guilds:
              - guild-1
            allowed_channels:
              - channel-1
      ---
      Prompt
      """
    )
  end

  defp assert_eventually_pending_write(db_path, run_id, external_id, attempts \\ 20)

  defp assert_eventually_pending_write(db_path, run_id, external_id, attempts) when attempts > 0 do
    case RunLedger.list_events(db_path, run_id) do
      {:ok, events} ->
        if Enum.any?(events, &(&1["event_type"] == "pending_write" and &1["external_id"] == external_id)) do
          :ok
        else
          Process.sleep(50)
          assert_eventually_pending_write(db_path, run_id, external_id, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(50)
        assert_eventually_pending_write(db_path, run_id, external_id, attempts - 1)
    end
  end

  defp assert_eventually_pending_write(db_path, run_id, external_id, 0) do
    assert {:ok, events} = RunLedger.list_events(db_path, run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write" and &1["external_id"] == external_id))
  end

  defp assert_eventually_run_status(db_path, run_id, status, attempts \\ 20)

  defp assert_eventually_run_status(db_path, run_id, status, attempts) when attempts > 0 do
    case RunLedger.get_run(db_path, run_id) do
      {:ok, %{"status" => ^status}} ->
        :ok

      _ ->
        Process.sleep(50)
        assert_eventually_run_status(db_path, run_id, status, attempts - 1)
    end
  end

  defp assert_eventually_run_status(db_path, run_id, status, 0) do
    assert {:ok, %{"status" => ^status}} = RunLedger.get_run(db_path, run_id)
  end

  defp assert_discord_post_contains(channel_id, expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_discord_post_contains(channel_id, expected, deadline, [])
  end

  defp assert_discord_followup_failed_for(interaction_id, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {
        :telemetry,
        [:symphony, :surfer, :discord_followup_failed],
        %{count: 1},
        %{interaction_id: ^interaction_id} = metadata
      } ->
        metadata

      {:telemetry, [:symphony, :surfer, :discord_followup_failed], %{count: 1}, _metadata} ->
        assert_discord_followup_failed_for(interaction_id, deadline)
    after
      remaining_ms ->
        flunk("expected discord_followup_failed telemetry for #{inspect(interaction_id)}")
    end
  end

  defp do_assert_discord_post_contains(channel_id, expected, deadline, seen) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:discord_post, ^channel_id, body} ->
        if body =~ expected do
          body
        else
          do_assert_discord_post_contains(channel_id, expected, deadline, [body | seen])
        end
    after
      remaining_ms ->
        flunk("expected Discord post in #{channel_id} to contain #{inspect(expected)}, saw #{inspect(Enum.reverse(seen))}")
    end
  end

  defp claimed_operator_control_request!(db_path, suffix) do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-operator-#{suffix}",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement #{suffix}"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, "operator-control-#{suffix}", request, platform: :discord)

    request
  end

  defp linear_agent_body(webhook_id, session_id, issue_id) do
    Jason.encode!(%{
      webhookTimestamp: System.system_time(:millisecond),
      webhookId: webhook_id,
      type: "AgentSessionEvent",
      agentSession: %{
        id: session_id,
        issue: %{id: issue_id, identifier: "ENG-1", title: "Fix", state: %{name: "Todo"}}
      }
    })
  end

  defp linear_signature(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
