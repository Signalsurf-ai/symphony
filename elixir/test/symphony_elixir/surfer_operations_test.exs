defmodule SymphonyElixir.SurferOperationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.{
    Budget,
    CodexHealth,
    Lifecycle,
    Metrics,
    Operator,
    RunLedger,
    RunRequest,
    SecretRedactor,
    WorkspaceLifecycle
  }

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-ops-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm_rf(db_path) end)

    assert :ok = RunLedger.initialize(db_path)

    %{db_path: db_path}
  end

  test "lifecycle cancel marks an active run cancelled", %{db_path: db_path} do
    request = claimed_request!(db_path)

    assert :ok =
             RunLedger.update_status(db_path, request.run_id, "running",
               reason: "dispatch accepted",
               actor: "surfer"
             )

    assert :ok = Lifecycle.cancel(db_path, request.run_id, actor: "operator")
    assert {:ok, %{"status" => "cancelled"}} = RunLedger.get_run(db_path, request.run_id)
  end

  test "retry creates a linked queued run without mutating the failed run", %{db_path: db_path} do
    request = claimed_request!(db_path)

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, request.run_id, "failed", error_message: "boom")

    assert {:ok, retry} = Lifecycle.retry(db_path, request.run_id, actor: "operator", nonce: "n1")

    assert retry.previous_run_id == request.run_id
    assert retry.run_id != request.run_id
    assert {:ok, %{"status" => "failed"}} = RunLedger.get_run(db_path, request.run_id)
    assert {:ok, %{"status" => "queued"}} = RunLedger.get_run(db_path, retry.run_id)
    assert {:ok, links} = RunLedger.list_links(db_path, retry.run_id)
    assert Enum.any?(links, &(&1["kind"] == "retry_of" and &1["external_id"] == request.run_id))
    retry_run_id = retry.run_id

    assert {:ok, duplicate_retry} = Lifecycle.retry(db_path, request.run_id, actor: "operator", nonce: "n1")
    assert duplicate_retry.previous_run_id == request.run_id
    assert duplicate_retry.run_id == retry_run_id

    assert {:ok, ^retry_run_id} =
             RunLedger.lookup_idempotency_key(db_path, "operator_retry:#{request.run_id}:n1")
  end

  test "takeover marks the run awaiting review and records a human handoff note", %{db_path: db_path} do
    request = claimed_request!(db_path)

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")

    assert :ok =
             Lifecycle.takeover(db_path, request.run_id,
               actor: "operator:test",
               reason: "operator is taking over local fixes"
             )

    assert {:ok, %{"status" => "awaiting_review"}} = RunLedger.get_run(db_path, request.run_id)
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "handoff_note" and
               event["payload_json"] =~ "operator is taking over local fixes" and
               event["payload_json"] =~ "operator:test" and
               event["payload_json"] =~ "human"
           end)
  end

  test "GitHub PR open records link, event, and awaiting-review status", %{db_path: db_path} do
    request = claimed_request!(db_path)

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")

    assert :ok =
             Lifecycle.record_github_pr_opened(
               db_path,
               request.run_id,
               %{
                 number: 42,
                 url: "https://github.com/acme/web/pull/42",
                 title: "Fix routing",
                 state: "open"
               },
               actor: "surfer"
             )

    assert {:ok, %{"status" => "awaiting_review"}} = RunLedger.get_run(db_path, request.run_id)

    assert {:ok, links} = RunLedger.list_links(db_path, request.run_id)

    assert Enum.any?(links, fn link ->
             link["platform"] == "github" and link["kind"] == "pull_request" and
               link["external_id"] == "42" and link["url"] == "https://github.com/acme/web/pull/42"
           end)

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "github_pr_opened" and event["platform"] == "github" and
               event["external_id"] == "42" and event["payload_json"] =~ "Fix routing"
           end)
  end

  test "GitHub PR open updates Linear agent session external URLs", %{db_path: db_path} do
    previous_external_urls_fun = Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_external_urls_fun, previous_external_urls_fun) end)

    request = claimed_linear_request!(db_path, "session-pr-url-success")
    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_external_urls_fun, fn session_id, urls ->
      send(parent, {:linear_external_urls, session_id, urls})
      :ok
    end)

    assert :ok =
             Lifecycle.record_github_pr_opened(db_path, request.run_id, %{
               number: 42,
               url: "https://github.com/acme/web/pull/42",
               title: "Fix routing",
               state: "open"
             })

    assert_receive {:linear_external_urls, "session-pr-url-success", urls}
    assert Enum.any?(urls, &(&1 == %{label: "GitHub PR", url: "https://github.com/acme/web/pull/42"}))

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert status_transition_payload(events, "awaiting_review")["external_write_status"]["linear"] == "posted"
  end

  test "GitHub PR open queues pending Linear external URL update when the write fails", %{db_path: db_path} do
    previous_external_urls_fun = Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_external_urls_fun, previous_external_urls_fun) end)

    request = claimed_linear_request!(db_path, "session-pr-url-fail")
    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")

    parent = self()
    handler_id = {__MODULE__, self(), :github_pr_external_url_failure_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :platform_write_failures],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:symphony_elixir, :surfer_linear_external_urls_fun, fn session_id, urls ->
      send(parent, {:linear_external_urls_attempt, session_id, urls})
      {:error, {:linear_down, "Authorization: Bearer linear-secret"}}
    end)

    assert :ok =
             Lifecycle.record_github_pr_opened(db_path, request.run_id, %{
               number: 42,
               url: "https://github.com/acme/web/pull/42",
               title: "Fix routing",
               state: "open"
             })

    external_id = "session-pr-url-fail:external_urls:#{request.run_id}:github_pr"
    assert_receive {:linear_external_urls_attempt, "session-pr-url-fail", urls}
    assert Enum.any?(urls, &(&1 == %{label: "GitHub PR", url: "https://github.com/acme/web/pull/42"}))

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "pending_write" and event["platform"] == "linear" and
               event["external_id"] == external_id and event["payload_json"] =~ "GitHub PR"
           end)

    refute Enum.any?(events, &String.contains?(&1["payload_json"], "linear-secret"))

    assert_receive {
      :telemetry,
      [:symphony, :surfer, :platform_write_failures],
      %{count: 1},
      metadata
    }

    assert metadata.run_id == request.run_id
    assert metadata.platform == "linear"
    assert metadata.external_id == external_id
    assert metadata.reason =~ "[REDACTED]"
    refute metadata.reason =~ "linear-secret"

    assert status_transition_payload(events, "awaiting_review")["external_write_status"]["linear"] == "pending"
  end

  test "operator lookup returns a redacted run, events, and links", %{db_path: db_path} do
    request = claimed_request!(db_path)
    log_path = Path.join(System.tmp_dir!(), "surfer-operator-log-#{System.unique_integer([:positive])}.log")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      restore_app_env(:log_file, previous_log_file)
      File.rm_rf(log_path)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    File.write!(log_path, """
    2026-05-19 run_id=#{request.run_id} started
    2026-05-19 run_id=other-run discord_interaction_token=other-token
    2026-05-19 run_id=#{request.run_id} Authorization: Bearer super-secret-token
    """)

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, request.run_id, "failed", error_code: "codex_error", error_message: "boom")

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "platform_write",
               platform: "discord",
               payload: %{
                 body: "ok",
                 interaction_token: "secret-token",
                 platform_payload: %{
                   "type" => "AgentSessionEvent",
                   "request" => "raw platform request body must not be exposed"
                 }
               }
             })

    assert :ok =
             RunLedger.record_link(db_path, request.run_id, %{
               platform: "linear",
               kind: "issue",
               external_id: "issue-1",
               url: "https://linear.app/acme/issue/ENG-1/test"
             })

    assert {:ok, lookup} = Operator.lookup_run(db_path, request.run_id)
    assert lookup.run["id"] == request.run_id
    assert lookup.latest_error == %{"code" => "codex_error", "message" => "boom"}

    assert lookup.log_tail == [
             "2026-05-19 run_id=#{request.run_id} started",
             "2026-05-19 run_id=#{request.run_id} Authorization: Bearer [REDACTED]"
           ]

    assert [%{"kind" => "issue"}] = lookup.links
    encoded = Jason.encode!(lookup)
    refute encoded =~ "surfer implement routing"
    refute encoded =~ "raw platform request body"
    refute encoded =~ "secret-token"
    refute encoded =~ "super-secret-token"
    refute encoded =~ "other-token"
    assert encoded =~ "[REDACTED]"
  end

  test "operator lookup tails run-scoped structured JSONL logs from Surfer storage", %{db_path: db_path} do
    logs_dir = Path.join(System.tmp_dir!(), "surfer-operator-jsonl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(logs_dir)

    on_exit(fn -> File.rm_rf(logs_dir) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        storage:
          logs_dir: #{inspect(logs_dir)}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    request = claimed_request!(db_path)

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "platform_write",
               platform: "discord",
               payload: %{body: "Authorization: Bearer jsonl-secret", ok: true}
             })

    assert {:ok, lookup} = Operator.lookup_run(db_path, request.run_id)
    assert [line] = lookup.log_tail
    assert {:ok, decoded} = Jason.decode(line)
    assert decoded["run_id"] == request.run_id
    assert decoded["event_type"] == "platform_write"
    assert decoded["payload"]["body"] == "[REDACTED]"
    refute line =~ "jsonl-secret"
  end

  test "daily budget cap rejects new dispatch once recorded usage reaches the cap", %{db_path: db_path} do
    parent = self()
    handler_id = {__MODULE__, self(), :budget_remaining_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :daily_codex_budget_remaining],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = claimed_request!(db_path)

    assert :ok = Budget.record_usage(db_path, request.run_id, 1.25)
    assert :ok = Budget.check_daily_cap(db_path, 2.0)
    assert_receive {:telemetry, [:symphony, :surfer, :daily_codex_budget_remaining], %{amount_usd: remaining}, metadata}
    assert_in_delta remaining, 0.75, 0.001
    assert metadata.limit_usd == 2.0
    assert metadata.used_usd >= 1.25

    assert {:error, {:daily_budget_cap_exceeded, %{limit_usd: 1.0, used_usd: used}}} =
             Budget.check_daily_cap(db_path, 1.0)

    assert used >= 1.25
  end

  test "per-run budget cap marks the run failed once recorded usage reaches the cap", %{db_path: db_path} do
    parent = self()
    handler_id = {__MODULE__, self(), :per_run_budget_cap_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :budget_cap_hits],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = claimed_request!(db_path)

    assert :ok = Budget.record_usage(db_path, request.run_id, 0.75)
    assert :ok = Budget.check_run_cap(db_path, request.run_id, 1.0)

    assert :ok = Budget.record_usage(db_path, request.run_id, 0.30)

    assert {:error, {:run_budget_cap_exceeded, %{limit_usd: 1.0, run_id: run_id, used_usd: used}}} =
             Budget.check_run_cap(db_path, request.run_id, 1.0)

    assert run_id == request.run_id
    assert used >= 1.05

    assert_receive {:telemetry, [:symphony, :surfer, :budget_cap_hits], %{count: 1}, metadata}
    assert metadata.run_id == request.run_id
    assert metadata.limit_usd == 1.0
    assert metadata.used_usd >= 1.05

    assert {:ok, %{"status" => "failed", "error_code" => "budget_cap"} = run} =
             RunLedger.get_run(db_path, request.run_id)

    assert run["error_message"] =~ "Per-run Codex budget cap exceeded"
  end

  test "Codex OAuth health check pauses Surfer without leaking command output" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        codex:
          auth: openai_pro_oauth
          app_server_version: "0.131.0"
          health_check_command: codex login status
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    parent = self()

    runner = fn command ->
      send(parent, {:codex_health_command, command})
      {"expired access_token=secret-token", 1}
    end

    log =
      capture_log(fn ->
        assert {:error, {:codex_health_check_failed, 1}} = CodexHealth.run_startup_check(runner: runner)
      end)

    assert_receive {:codex_health_command, "codex login status"}
    assert %{paused: true, actor: "surfer:codex_health", reason: reason} = Operator.pause_status(false)
    assert reason == "Codex OpenAI Pro OAuth health check failed with exit status 1"
    refute log =~ "secret-token"
  end

  test "Codex OAuth health check passes through the configured shell command" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)

    settings =
      codex_health_settings(%{
        auth: "openai_pro_oauth",
        health_check_command: "printf surfer-codex-ok"
      })

    log =
      capture_log(fn ->
        assert :ok = CodexHealth.run_startup_check(settings: {:ok, settings})
      end)

    assert %{paused: false, actor: nil, reason: nil} = Operator.pause_status(false)
    assert log =~ "Codex OpenAI Pro OAuth startup health check passed"
  end

  test "Codex OAuth health check uses configured Codex home" do
    previous_home = System.get_env("CODEX_HOME")
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn ->
      restore_env("CODEX_HOME", previous_home)
      restore_app_env(:surfer_runtime_pause, previous_pause)
    end)

    codex_home = Path.join(System.tmp_dir!(), "surfer-codex-home-#{System.unique_integer([:positive])}")
    System.put_env("CODEX_HOME", "wrong-codex-home")

    settings =
      codex_health_settings(%{
        auth: "openai_pro_oauth",
        home: codex_home,
        health_check_command: ~s([ "$CODEX_HOME" = "#{codex_home}" ])
      })

    assert :ok = CodexHealth.run_startup_check(settings: {:ok, settings})
    assert %{paused: false, actor: nil, reason: nil} = Operator.pause_status(false)
  end

  test "Codex OAuth health check leaves CODEX_HOME inherited when configured home is blank" do
    previous_home = System.get_env("CODEX_HOME")
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn ->
      restore_env("CODEX_HOME", previous_home)
      restore_app_env(:surfer_runtime_pause, previous_pause)
    end)

    System.put_env("CODEX_HOME", "inherited-codex-home")

    settings =
      codex_health_settings(%{
        auth: "openai_pro_oauth",
        home: "  ",
        health_check_command: ~s([ "$CODEX_HOME" = "inherited-codex-home" ])
      })

    assert :ok = CodexHealth.run_startup_check(settings: {:ok, settings})
  end

  test "Codex OAuth health check pauses Surfer when the runner cannot execute" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)

    settings = codex_health_settings(%{auth: "openai_pro_oauth", health_check_command: "codex login status"})

    log =
      capture_log(fn ->
        assert {:error, {:codex_health_check_failed, :enoent}} =
                 CodexHealth.run_startup_check(settings: {:ok, settings}, runner: fn _command -> {:error, :enoent} end)
      end)

    assert %{paused: true, actor: "surfer:codex_health", reason: reason} = Operator.pause_status(false)
    assert reason == "Codex OpenAI Pro OAuth health check failed"
    assert log =~ "Codex OpenAI Pro OAuth health check failed: :enoent"
  end

  test "Codex OAuth health check redacts token-shaped runner errors" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)

    settings = codex_health_settings(%{auth: "openai_pro_oauth", health_check_command: "codex login status"})

    log =
      capture_log(fn ->
        assert {:error, {:codex_health_check_failed, {:cli_error, "Authorization: Bearer codex-secret"}}} =
                 CodexHealth.run_startup_check(
                   settings: {:ok, settings},
                   runner: fn _command -> {:error, {:cli_error, "Authorization: Bearer codex-secret"}} end
                 )
      end)

    assert log =~ "[REDACTED]"
    refute log =~ "codex-secret"
  end

  test "Codex OAuth health check fails closed when the shell cannot start" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)

    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)

    settings = codex_health_settings(%{auth: "openai_pro_oauth", health_check_command: "codex login status"})
    missing_shell = Path.join(System.tmp_dir!(), "missing-surfer-shell-#{System.unique_integer([:positive])}")

    log =
      capture_log(fn ->
        assert {:error, {:codex_health_check_failed, %ErlangError{original: :enoent}}} =
                 CodexHealth.run_startup_check(settings: {:ok, settings}, shell_path: missing_shell)
      end)

    assert %{paused: true, actor: "surfer:codex_health", reason: reason} = Operator.pause_status(false)
    assert reason == "Codex OpenAI Pro OAuth health check failed"
    assert log =~ "%ErlangError{original: :enoent"
  end

  test "Codex health check skips cleanly when config is unavailable" do
    log =
      capture_log(fn ->
        assert :ok = CodexHealth.run_startup_check(settings: {:error, :missing_workflow})
      end)

    assert log =~ "Skipping Codex startup health check because config is unavailable: :missing_workflow"
  end

  test "Codex health check is skipped when Surfer OAuth auth is not configured" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    runner = fn _command -> flunk("health check should not run without Surfer OAuth auth") end

    assert :ok = CodexHealth.run_startup_check(runner: runner)
  end

  test "Docker image declares a local operator state health check" do
    dockerfile = File.read!(Path.expand("../../Dockerfile", __DIR__))

    assert dockerfile =~ "HEALTHCHECK"
    assert dockerfile =~ "http://127.0.0.1:4000/api/v1/state"
  end

  test "Docker image does not install the host sqlite3 CLI for the ledger" do
    dockerfile = File.read!(Path.expand("../../Dockerfile", __DIR__))

    refute dockerfile =~ ~r/^\s*sqlite3\s*\\/m
  end

  test "Docker compose layers example env with optional local secret override" do
    compose = YamlElixir.read_from_file!(Path.expand("../../docker-compose.surfer.yml", __DIR__))

    assert [
             %{"path" => ".env.surfer.example"},
             %{"path" => ".env.surfer", "required" => false}
           ] = get_in(compose, ["services", "surfer", "env_file"])
  end

  test "Docker compose binds the Surfer HTTP service to loopback by default" do
    compose = YamlElixir.read_from_file!(Path.expand("../../docker-compose.surfer.yml", __DIR__))

    assert ["${SURFER_HOST_BIND:-127.0.0.1}:4000:4000"] = get_in(compose, ["services", "surfer", "ports"])
  end

  test "Surfer workflow disables the legacy Linear project poller by default" do
    assert {:ok, %{config: workflow}} =
             SymphonyElixir.Workflow.load(Path.expand("../../SURFER_WORKFLOW.example.md", __DIR__))

    assert get_in(workflow, ["polling", "enabled"]) == false
    assert get_in(workflow, ["polling", "interval_ms"]) == 5000
  end

  test "operator requeues pending platform writes and records drained or failed outcomes", %{db_path: db_path} do
    request = claimed_request!(db_path)

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:response",
               idempotency_hash: "hash-response",
               payload: %{type: "response", body: "Done"}
             })

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:error",
               idempotency_hash: "hash-error",
               payload: %{type: "error", body: "Failed"}
             })

    parent = self()

    retry_fun = fn write ->
      send(parent, {:retry_write, write["external_id"], write["idempotency_hash"]})

      case write["external_id"] do
        "session-1:response" -> {:ok, %{status: 200}}
        "session-1:error" -> {:error, :linear_down}
      end
    end

    assert {:ok, %{attempted: 2, drained: 1, failed: 1}} =
             Lifecycle.requeue_pending_writes(db_path, retry_fun: retry_fun, actor: "operator")

    assert_receive {:retry_write, "session-1:response", "hash-response"}
    assert_receive {:retry_write, "session-1:error", "hash-error"}
    assert {:ok, []} = RunLedger.list_pending_writes(db_path)

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write_drained" and &1["external_id"] == "session-1:response"))
    assert Enum.any?(events, &(&1["event_type"] == "pending_write_failed" and &1["external_id"] == "session-1:error"))

    failed = Enum.find(events, &(&1["event_type"] == "pending_write_failed"))
    assert Jason.decode!(failed["payload_json"])["reason"] == ":linear_down"
  end

  test "operator retries supported Linear pending writes through platform clients", %{db_path: db_path} do
    previous_started_fun = Application.get_env(:symphony_elixir, :surfer_linear_activity_fun)
    previous_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    previous_external_urls_fun = Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun)

    on_exit(fn ->
      restore_app_env(:surfer_linear_activity_fun, previous_started_fun)
      restore_app_env(:surfer_linear_session_activity_fun, previous_activity_fun)
      restore_app_env(:surfer_linear_external_urls_fun, previous_external_urls_fun)
    end)

    request = claimed_request!(db_path)
    run_id = request.run_id

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:response",
               idempotency_hash: "hash-response",
               payload: %{session_id: "session-1", type: "response", body: "Done"}
             })

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:started",
               idempotency_hash: "hash-started",
               payload: %{session_id: "session-1", type: "started", run_id: request.run_id}
             })

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:external_urls",
               idempotency_hash: "hash-urls",
               payload: %{
                 session_id: "session-1",
                 type: "external_urls",
                 external_urls: [%{label: "Surfer run", url: "https://surfer.example.com/runs/surf-1"}]
               }
             })

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity_retry, session_id, type, body})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_activity_fun, fn session_id, run_id ->
      send(parent, {:linear_started_retry, session_id, run_id})
      :ok
    end)

    Application.put_env(:symphony_elixir, :surfer_linear_external_urls_fun, fn session_id, urls ->
      send(parent, {:linear_external_urls_retry, session_id, urls})
      :ok
    end)

    assert {:ok, %{attempted: 3, drained: 3, failed: 0}} = Operator.requeue_pending_writes(db_path)

    assert_receive {:linear_activity_retry, "session-1", :response, "Done"}
    assert_receive {:linear_started_retry, "session-1", ^run_id}
    assert_receive {:linear_external_urls_retry, "session-1", [%{"label" => "Surfer run", "url" => "https://surfer.example.com/runs/surf-1"}]}
    assert {:ok, []} = RunLedger.list_pending_writes(db_path)
  end

  test "pending write retry emits duration and failure metrics", %{db_path: db_path} do
    parent = self()
    handler_id = {__MODULE__, self(), :platform_write_metrics}

    :telemetry.attach_many(
      handler_id,
      [
        [:symphony, :surfer, :platform_write_ms],
        [:symphony, :surfer, :platform_write_failures]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = claimed_request!(db_path)

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-metrics:error",
               idempotency_hash: "hash-error",
               payload: %{type: "error", body: "Failed"}
             })

    retry_fun = fn _write -> {:error, :linear_down} end

    assert {:ok, %{attempted: 1, drained: 0, failed: 1}} =
             Lifecycle.requeue_pending_writes(db_path, retry_fun: retry_fun, actor: "operator")

    assert_receive {:telemetry, [:symphony, :surfer, :platform_write_ms], %{duration_ms: duration_ms}, write_metadata}
    assert duration_ms >= 0
    assert write_metadata.platform == "linear"
    assert write_metadata.external_id == "session-metrics:error"
    assert write_metadata.run_id == request.run_id

    assert_receive {:telemetry, [:symphony, :surfer, :platform_write_failures], %{count: 1}, failure_metadata}
    assert failure_metadata.platform == "linear"
    assert failure_metadata.reason == ":linear_down"
  end

  test "ledger emits Surfer telemetry for started, duplicate, and terminal runs", %{db_path: db_path} do
    parent = self()
    handler_id = {__MODULE__, self(), :surfer_metrics}

    events = [
      [:symphony, :surfer, :runs_started],
      [:symphony, :surfer, :duplicate_events],
      [:symphony, :surfer, :runs_completed],
      [:symphony, :surfer, :runs_failed],
      [:symphony, :surfer, :runs_cancelled]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = discord_request!()
    key = RunRequest.idempotency_key(request)
    completed_request = discord_request!()
    completed_key = RunRequest.idempotency_key(completed_request)
    cancelled_request = discord_request!()
    cancelled_key = RunRequest.idempotency_key(cancelled_request)

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, key, request, platform: :discord)
    assert {:ok, %{status: :duplicate}} = RunLedger.claim_run(db_path, key, %{request | run_id: "other"}, platform: :discord)
    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, request.run_id, "failed", error_message: "boom")

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, completed_key, completed_request, platform: :discord)

    assert :ok = RunLedger.update_status(db_path, completed_request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, completed_request.run_id, "completed")

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, cancelled_key, cancelled_request, platform: :discord)

    assert :ok = RunLedger.update_status(db_path, cancelled_request.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, cancelled_request.run_id, "cancelled")

    assert_receive {:telemetry, [:symphony, :surfer, :runs_started], %{count: 1}, %{run_id: run_id}}
    assert run_id == request.run_id
    assert_receive {:telemetry, [:symphony, :surfer, :duplicate_events], %{count: 1}, %{run_id: ^run_id}}
    assert_receive {:telemetry, [:symphony, :surfer, :runs_failed], %{count: 1}, %{run_id: ^run_id}}
    assert_receive {:telemetry, [:symphony, :surfer, :runs_completed], %{count: 1}, %{run_id: completed_run_id}}
    assert completed_run_id == completed_request.run_id
    assert_receive {:telemetry, [:symphony, :surfer, :runs_cancelled], %{count: 1}, %{run_id: cancelled_run_id}}
    assert cancelled_run_id == cancelled_request.run_id
  end

  test "telemetry metadata redacts token-shaped strings outside secret keys" do
    parent = self()
    handler_id = {__MODULE__, self(), :surfer_metric_redaction}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :redaction_probe],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Metrics.emit(
      :redaction_probe,
      %{count: 1},
      %{
        message: "Authorization: Bearer telemetry-secret",
        bot_auth: "Authorization: Bot discord-bot-secret",
        discord_webhook_url: "url=https://discord.com/api/v10/webhooks/app-1/interaction-token-secret/messages/@original",
        nested: [%{body: "api_key=inline-telemetry-secret"}],
        tuple_reason: {:discord_5xx, "url=https://discord.com/api/v10/webhooks/app-1/tuple-token-secret/messages/@original"},
        token: "named-secret",
        api_key: "structured-telemetry-api-key",
        password: "structured-telemetry-password"
      }
    )

    assert_receive {:telemetry, [:symphony, :surfer, :redaction_probe], %{count: 1}, metadata}
    encoded = inspect(metadata)

    assert metadata.message == "Authorization: Bearer [REDACTED]"
    assert metadata.bot_auth == "Authorization: Bot [REDACTED]"
    assert metadata.discord_webhook_url == "url=https://discord.com/api/v10/webhooks/app-1/[REDACTED]/messages/@original"
    assert [%{body: "api_key=[REDACTED]"}] = metadata.nested
    assert metadata.tuple_reason == {:discord_5xx, "url=https://discord.com/api/v10/webhooks/app-1/[REDACTED]/messages/@original"}
    assert metadata.token == "[REDACTED]"
    assert metadata.api_key == "[REDACTED]"
    assert metadata.password == "[REDACTED]"
    refute encoded =~ "telemetry-secret"
    refute encoded =~ "discord-bot-secret"
    refute encoded =~ "interaction-token-secret"
    refute encoded =~ "inline-telemetry-secret"
    refute encoded =~ "tuple-token-secret"
    refute encoded =~ "named-secret"
    refute encoded =~ "structured-telemetry-api-key"
    refute encoded =~ "structured-telemetry-password"
  end

  test "secret redactor redacts quoted inline secret assignments" do
    redacted =
      SecretRedactor.redact_text(~s(access_token: "oauth-secret" webhook_secret='hook-secret' bot_token = "bot-secret" LINEAR_ACCESS_TOKEN=linear-secret))

    assert redacted ==
             ~s(access_token: "[REDACTED]" webhook_secret='[REDACTED]' bot_token = "[REDACTED]" LINEAR_ACCESS_TOKEN=[REDACTED])

    refute redacted =~ "oauth-secret"
    refute redacted =~ "hook-secret"
    refute redacted =~ "bot-secret"
    refute redacted =~ "linear-secret"
  end

  test "workspace cleanup preserves active runs and removes expired terminal workspaces", %{db_path: db_path} do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "surfer-workspaces-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    active = claimed_request!(db_path)
    completed = claimed_request!(db_path)
    failed = claimed_request!(db_path)

    assert :ok = RunLedger.update_status(db_path, active.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, completed.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, failed.run_id, "running")

    old = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.to_iso8601()
    assert :ok = RunLedger.update_status(db_path, completed.run_id, "completed", now: old)
    assert :ok = RunLedger.update_status(db_path, failed.run_id, "failed", now: old)

    for run_id <- [active.run_id, completed.run_id, failed.run_id] do
      File.mkdir_p!(Path.join([workspace_root, "web", run_id]))
    end

    assert {:ok, %{removed: removed, preserved: preserved}} =
             WorkspaceLifecycle.cleanup(workspace_root, db_path,
               successful_ttl_days: 14,
               failed_ttl_days: 30,
               now: DateTime.utc_now()
             )

    assert completed.run_id in removed
    assert failed.run_id in removed
    assert active.run_id in preserved
    assert File.dir?(Path.join([workspace_root, "web", active.run_id]))
    refute File.exists?(Path.join([workspace_root, "web", completed.run_id]))
    refute File.exists?(Path.join([workspace_root, "web", failed.run_id]))
  end

  test "disk pressure check emits workspace disk usage gauge" do
    parent = self()
    handler_id = {__MODULE__, self(), :workspace_disk_usage_metric}

    :telemetry.attach(
      handler_id,
      [:symphony, :surfer, :workspace_disk_usage_bytes],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    disk_usage_fun = fn "/tmp/surfer-workspaces" ->
      {:ok, %{used_percent: 42, used_bytes: 123_456}}
    end

    assert {:ok, false} =
             WorkspaceLifecycle.disk_pressure?("/tmp/surfer-workspaces", 90, disk_usage_fun: disk_usage_fun)

    assert_receive {:telemetry, [:symphony, :surfer, :workspace_disk_usage_bytes], %{bytes: 123_456}, metadata}
    assert metadata.workspace_root == "/tmp/surfer-workspaces"
    assert metadata.used_percent == 42
  end

  defp claimed_request!(db_path) do
    request = discord_request!()

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    request
  end

  defp claimed_linear_request!(db_path, session_id) do
    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "action" => "created",
               "agentSession" => %{
                 "id" => session_id,
                 "issue" => %{
                   "id" => "issue-#{session_id}",
                   "identifier" => "ENG-1",
                   "title" => "Fix routing",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :linear)

    request
  end

  defp discord_request! do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1-#{System.unique_integer([:positive])}",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer implement routing"
             })

    request
  end

  defp status_transition_payload(events, to_status) do
    events
    |> Enum.find(fn event ->
      event["event_type"] == "status_transition" and
        event["payload_json"] |> Jason.decode!() |> Map.get("to") == to_status
    end)
    |> Map.fetch!("payload_json")
    |> Jason.decode!()
  end

  defp codex_health_settings(codex) do
    %{
      surfer: %{
        paused: false,
        codex: codex
      }
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
