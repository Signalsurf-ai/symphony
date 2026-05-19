defmodule SymphonyElixir.SurferPromptOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.{Budget, Operator, RunLedger, RunRequest}

  test "prompt builder exposes Surfer context to the first Codex turn" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: """
      Run: {{ surfer.run_id }}
      Mode: {{ surfer.request_mode }}
      Platform: {{ surfer.source_platform }}
      Trigger: {{ surfer.trigger_type }}
      Org: {{ surfer.organization_id }}
      Discord: {{ surfer.discord.message_id }}
      Brain: {{ surfer.company_brain_refs[0].path }}
      Read only: {{ surfer.constraints.read_only }}
      Allow PR: {{ surfer.constraints.allow_pr_creation }}
      """
    )

    issue = %Issue{id: "issue-1", identifier: "ENG-1", title: "Fix", state: "Todo"}

    prompt =
      PromptBuilder.build_prompt(issue,
        surfer_context: %{
          run_id: "surf_run_1",
          request_mode: "code_question",
          source_platform: "discord",
          trigger_type: "slash_command",
          organization_id: "org-1",
          discord: %{message_id: "message-1"},
          company_brain_refs: [%{path: "meetings/2026-05-01.md"}],
          constraints: %{read_only: true, allow_pr_creation: false}
        }
      )

    assert prompt =~ "Run: surf_run_1"
    assert prompt =~ "Mode: code_question"
    assert prompt =~ "Platform: discord"
    assert prompt =~ "Trigger: slash_command"
    assert prompt =~ "Org: org-1"
    assert prompt =~ "Discord: message-1"
    assert prompt =~ "Brain: meetings/2026-05-01.md"
    assert prompt =~ "Read only: true"
    assert prompt =~ "Allow PR: false"
  end

  test "orchestrator direct dispatch converts a normalized run request into an agent run" do
    parent = self()
    handler_id = {__MODULE__, self(), :orchestrator_runtime_metrics}

    :telemetry.attach_many(
      handler_id,
      [
        [:symphony, :surfer, :running_runs],
        [:symphony, :surfer, :queued_runs],
        [:symphony, :surfer, :codex_run_ms]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    orchestrator_name = Module.concat(__MODULE__, :DirectDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "organizationId" => "org-1",
               "agentSession" => %{
                 "id" => "session-dispatch-1",
                 "promptContext" => "Linear context\nAuthorization: Bearer should-not-cross",
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    request = %{request | routing: %{repository_key: "web", repository_full_name: "acme/web"}}

    runner_fun = fn issue, _recipient, opts ->
      send(parent, {:runner_called, issue, opts})
      :ok
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
        assert_receive {:runner_called, issue, opts}, 1_000
        assert issue.id == "issue-1"
        assert issue.identifier == "ENG-1"
        assert opts[:surfer_context].run_id == request.run_id
        assert opts[:workspace_identifier] == ["web", request.run_id]
        assert opts[:surfer_context].prompt_context =~ "Linear context"
        assert opts[:surfer_context].prompt_context =~ "Authorization: Bearer [REDACTED]"
        refute opts[:surfer_context].prompt_context =~ "should-not-cross"
        assert_receive {:telemetry, [:symphony, :surfer, :running_runs], %{count: 1}, running_metadata}
        assert running_metadata.source == :orchestrator
        assert_receive {:telemetry, [:symphony, :surfer, :queued_runs], %{count: 0}, queued_metadata}
        assert queued_metadata.source == :orchestrator

        assert_receive {:telemetry, [:symphony, :surfer, :codex_run_ms], %{duration_ms: duration_ms}, run_metadata},
                       5_000

        assert duration_ms >= 0
        assert run_metadata.run_id == request.run_id
      end)

    assert log =~ "run_id=#{request.run_id}"
  end

  test "orchestrator retrieves scoped Company Brain refs before rendering Surfer context" do
    parent = self()
    previous_fetch_fun = Application.get_env(:symphony_elixir, :surfer_company_brain_fetch_fun)
    on_exit(fn -> restore_app_env(:surfer_company_brain_fetch_fun, previous_fetch_fun) end)

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
            company_brain_repo: acme/company-brain
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    Application.put_env(:symphony_elixir, :surfer_company_brain_fetch_fun, fn repo, paths ->
      send(parent, {:company_brain_fetch, repo, paths})

      {:ok,
       [
         %{path: "meetings/2026-05-01.md", url: "https://github.com/acme/company-brain/blob/main/meetings/2026-05-01.md", summary: "Routing decision"},
         %{path: "private/out-of-scope.md", url: "https://github.com/acme/company-brain/blob/main/private/out-of-scope.md", summary: "Do not include"}
       ]}
    end)

    orchestrator_name = Module.concat(__MODULE__, :CompanyBrainDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    repositories = [
      %{key: "web", repo: "acme/web", linear_team_ids: ["team-web"], company_brain_paths: ["meetings/"]}
    ]

    request = routed_linear_request!("issue-company-brain-1", "WEB-1", "team-web", repositories)

    runner_fun = fn _issue, _recipient, opts ->
      send(parent, {:runner_context, opts[:surfer_context]})
      :ok
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:company_brain_fetch, "acme/company-brain", ["meetings/"]}
    assert_receive {:runner_context, context}

    assert [
             %{
               path: "meetings/2026-05-01.md",
               authority: :background,
               role: :background_context,
               authoritative?: false
             }
           ] = context.company_brain_refs
  end

  test "orchestrator does not load Company Brain by default from global allowed paths" do
    parent = self()
    previous_fetch_fun = Application.get_env(:symphony_elixir, :surfer_company_brain_fetch_fun)
    on_exit(fn -> restore_app_env(:surfer_company_brain_fetch_fun, previous_fetch_fun) end)

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
            company_brain_repo: acme/company-brain
            company_brain_paths:
              - meetings/
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    Application.put_env(:symphony_elixir, :surfer_company_brain_fetch_fun, fn repo, paths ->
      send(parent, {:unexpected_company_brain_fetch, repo, paths})
      {:ok, [%{path: "meetings/2026-05-01.md", summary: "Should not load by default"}]}
    end)

    orchestrator_name = Module.concat(__MODULE__, :CompanyBrainDefaultOffOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    repositories = [
      %{key: "web", repo: "acme/web", linear_team_ids: ["team-web"]}
    ]

    request = routed_linear_request!("issue-company-brain-default-off-1", "WEB-2", "team-web", repositories)

    runner_fun = fn _issue, _recipient, opts ->
      send(parent, {:runner_context, opts[:surfer_context]})
      :ok
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:runner_context, context}
    refute_receive {:unexpected_company_brain_fetch, _repo, _paths}, 100
    assert context.company_brain_refs == []
  end

  test "orchestrator direct dispatch refuses an already claimed Linear issue" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :ClaimedDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-claim-1",
                 "issue" => %{
                   "id" => "issue-claim-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:runner_started, runner_pid}, 1_000

    assert {:error, {:already_claimed, "issue-claim-1"}} =
             Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)

    send(runner_pid, :release_runner)
  end

  test "orchestrator marks a claimed Linear issue conflict as awaiting input in the ledger" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-claimed-dispatch-ledger-#{System.unique_integer([:positive])}.sqlite3"
      )

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

    parent = self()
    previous_session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_session_activity_fun) end)
    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn _session_id, _type, _body -> :ok end)

    orchestrator_name = Module.concat(__MODULE__, :ClaimedDispatchLedgerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request_one} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-claim-1",
                 "issue" => %{
                   "id" => "issue-claim-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert {:ok, request_two} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-claim-2",
                 "issue" => %{
                   "id" => "issue-claim-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request_one), request_one)

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request_one, runner_fun: runner_fun)
    assert_receive {:runner_started, runner_pid}, 1_000

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request_two), request_two)

    assert {:error, {:already_claimed, "issue-claim-1"}} =
             Orchestrator.dispatch_run(orchestrator_name, request_two, runner_fun: runner_fun)

    assert {:ok, run} = RunLedger.get_run(db_path, request_two.run_id)
    assert run["status"] == "awaiting_input"
    assert run["error_code"] == "already_claimed"
    assert run["error_message"] =~ "issue-claim-1"

    assert {:ok, events} = RunLedger.list_events(db_path, request_two.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "status_transition" and &1["payload_json"] =~ "already claimed"))

    send(runner_pid, :release_runner)
  end

  test "orchestrator refuses a ledger-claimed Linear issue after restart" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-ledger-claimed-dispatch-#{System.unique_integer([:positive])}.sqlite3"
      )

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

    assert {:ok, existing_request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-ledger-claim-1",
                 "issue" => %{
                   "id" => "issue-ledger-claim-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert {:ok, incoming_request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-ledger-claim-2",
                 "issue" => %{
                   "id" => "issue-ledger-claim-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    existing_key = RunRequest.idempotency_key(existing_request)
    incoming_key = RunRequest.idempotency_key(incoming_request)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, existing_key, existing_request, platform: :linear)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, incoming_key, incoming_request, platform: :linear)

    orchestrator_name = Module.concat(__MODULE__, :LedgerClaimedAfterRestartOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    parent = self()

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:unexpected_runner_started, self()})
      :ok
    end

    assert {:error, {:already_claimed, "issue-ledger-claim-1"}} =
             Orchestrator.dispatch_run(orchestrator_name, incoming_request, runner_fun: runner_fun)

    refute_receive {:unexpected_runner_started, _pid}, 100

    assert {:ok, run} = RunLedger.get_run(db_path, incoming_request.run_id)
    assert run["status"] == "awaiting_input"
    assert run["error_code"] == "already_claimed"
    assert run["error_message"] =~ "issue-ledger-claim-1"
  end

  test "orchestrator direct dispatch enforces one write run per routed repository" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :RepositoryClaimOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    repositories = [
      %{key: "web", repo: "acme/web", linear_team_ids: ["team-web"]},
      %{key: "api", repo: "acme/api", linear_team_ids: ["team-api"]}
    ]

    request_one = routed_linear_request!("issue-web-1", "WEB-1", "team-web", repositories)
    request_two = routed_linear_request!("issue-web-2", "WEB-2", "team-web", repositories)
    request_three = routed_linear_request!("issue-api-1", "API-1", "team-api", repositories)

    runner_fun = fn issue, _recipient, _opts ->
      send(parent, {:repo_runner_started, issue.id, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request_one, runner_fun: runner_fun)
    assert_receive {:repo_runner_started, "issue-web-1", first_pid}, 1_000

    assert {:error, {:repository_busy, "web"}} =
             Orchestrator.dispatch_run(orchestrator_name, request_two, runner_fun: runner_fun)

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request_three, runner_fun: runner_fun)
    assert_receive {:repo_runner_started, "issue-api-1", second_pid}, 1_000

    send(first_pid, :release_runner)
    send(second_pid, :release_runner)
  end

  test "orchestrator marks repository write conflicts as awaiting input in the ledger" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-repository-conflict-ledger-#{System.unique_integer([:positive])}.sqlite3"
      )

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

    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :RepositoryConflictLedgerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    repositories = [
      %{key: "web", repo: "acme/web", linear_team_ids: ["team-web"]}
    ]

    request_one = routed_linear_request!("issue-web-1", "WEB-1", "team-web", repositories)
    request_two = routed_linear_request!("issue-web-2", "WEB-2", "team-web", repositories)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request_one), request_one)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request_two), request_two)

    runner_fun = fn issue, _recipient, _opts ->
      send(parent, {:repo_runner_started, issue.id, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request_one, runner_fun: runner_fun)
    assert_receive {:repo_runner_started, "issue-web-1", runner_pid}, 1_000

    assert {:error, {:repository_busy, "web"}} =
             Orchestrator.dispatch_run(orchestrator_name, request_two, runner_fun: runner_fun)

    assert {:ok, run} = RunLedger.get_run(db_path, request_two.run_id)
    assert run["status"] == "awaiting_input"
    assert run["error_code"] == "repository_busy"
    assert run["error_message"] =~ "web"

    assert {:ok, events} = RunLedger.list_events(db_path, request_two.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "status_transition" and &1["payload_json"] =~ "repository busy"))

    send(runner_pid, :release_runner)
  end

  test "orchestrator startup runs Surfer workspace retention cleanup from the ledger" do
    root = Path.join(System.tmp_dir!(), "surfer-startup-cleanup-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    db_path = Path.join([root, "state", "surfer.sqlite3"])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.dirname(db_path))
    assert :ok = RunLedger.initialize(db_path)

    active = discord_request!("message-active")
    completed = discord_request!("message-completed")
    failed = discord_request!("message-failed")

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(active), active, platform: :discord)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(completed), completed, platform: :discord)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(failed), failed, platform: :discord)

    old_completed = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.to_iso8601()
    old_failed = DateTime.utc_now() |> DateTime.add(-20, :day) |> DateTime.to_iso8601()

    assert :ok = RunLedger.update_status(db_path, active.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, completed.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, failed.run_id, "running")
    assert :ok = RunLedger.update_status(db_path, completed.run_id, "completed", now: old_completed)
    assert :ok = RunLedger.update_status(db_path, failed.run_id, "failed", now: old_failed)

    for run_id <- [active.run_id, completed.run_id, failed.run_id] do
      File.mkdir_p!(Path.join([workspace_root, "web", run_id]))
    end

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      workspace:
        root: #{workspace_root}
      surfer:
        workspace_root: #{workspace_root}
        storage:
          sqlite_path: #{db_path}
          workspace_retention_days: 14
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:ok, _state} = Orchestrator.init([])

    assert File.dir?(Path.join([workspace_root, "web", active.run_id]))
    refute File.exists?(Path.join([workspace_root, "web", completed.run_id]))
    assert File.dir?(Path.join([workspace_root, "web", failed.run_id]))
  end

  test "orchestrator startup prunes expired Surfer ledger history after retention" do
    root = Path.join(System.tmp_dir!(), "surfer-startup-ledger-prune-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    db_path = Path.join([root, "state", "surfer.sqlite3"])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.dirname(db_path))
    assert :ok = RunLedger.initialize(db_path)

    old_terminal = discord_request!("message-ledger-prune-old")
    recent_terminal = discord_request!("message-ledger-prune-recent")
    old_key = RunRequest.idempotency_key(old_terminal)
    recent_key = RunRequest.idempotency_key(recent_terminal)

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, old_key, old_terminal, platform: :discord)
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, recent_key, recent_terminal, platform: :discord)

    old = DateTime.utc_now() |> DateTime.add(-91, :day) |> DateTime.to_iso8601()
    recent = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

    assert :ok = RunLedger.update_status(db_path, old_terminal.run_id, "running", now: old)
    assert :ok = RunLedger.update_status(db_path, old_terminal.run_id, "completed", now: old)
    assert :ok = RunLedger.update_status(db_path, recent_terminal.run_id, "running", now: recent)
    assert :ok = RunLedger.update_status(db_path, recent_terminal.run_id, "completed", now: recent)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      workspace:
        root: #{workspace_root}
      surfer:
        workspace_root: #{workspace_root}
        storage:
          sqlite_path: #{db_path}
          retention_days: 90
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:ok, _state} = Orchestrator.init([])

    assert {:error, :not_found} = RunLedger.get_run(db_path, old_terminal.run_id)
    assert {:error, :not_found} = RunLedger.lookup_idempotency_key(db_path, old_key)
    assert {:ok, _run} = RunLedger.get_run(db_path, recent_terminal.run_id)
    assert {:ok, _run_id} = RunLedger.lookup_idempotency_key(db_path, recent_key)
  end

  test "orchestrator reports Linear final activity when direct dispatch completes" do
    parent = self()
    previous_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_fun) end)

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity, session_id, type, body})
      :ok
    end)

    orchestrator_name = Module.concat(__MODULE__, :LifecycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-1",
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, :runner_completed)
      :ok
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive :runner_completed, 1_000
    assert_receive {:linear_activity, "session-1", :response, body}, 1_000
    assert body =~ request.run_id
  end

  test "orchestrator still reports Linear final activity when runtime config is temporarily invalid" do
    parent = self()
    previous_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_fun) end)

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity, session_id, type, body})
      :ok
    end)

    orchestrator_name = Module.concat(__MODULE__, :InvalidConfigCompletionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-invalid-config",
                 "issue" => %{
                   "id" => "issue-invalid-config",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:runner_started, runner_pid}, 1_000

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    send(runner_pid, :release_runner)
    assert_receive {:linear_activity, "session-invalid-config", :response, body}, 1_000
    assert body =~ request.run_id
  end

  test "orchestrator direct dispatch writes run FSM transitions to ledger" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-orchestrator-ledger-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm_rf(db_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Prompt",
      tracker_kind: "memory"
    )

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

    parent = self()
    previous_session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_session_activity_fun) end)
    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn _session_id, _type, _body -> :ok end)

    orchestrator_name = Module.concat(__MODULE__, :LedgerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-1",
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request)

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, :runner_completed)
      :ok
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive :runner_completed, 1_000

    assert_eventually_status(db_path, request.run_id, "completed")
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "status_transition" and &1["payload_json"] =~ "running"))
    assert Enum.any?(events, &(&1["event_type"] == "status_transition" and &1["payload_json"] =~ "completed"))

    completed_payload = status_transition_payload(events, "completed")
    assert completed_payload["external_write_status"]["linear"] == "posted"
  end

  test "orchestrator stops an active direct dispatch when per-run budget is exhausted" do
    db_path = Path.join(System.tmp_dir!(), "surfer-run-budget-cap-#{System.unique_integer([:positive])}.sqlite3")
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
        codex:
          per_run_budget_usd: 1.0
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    parent = self()
    previous_session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_session_activity_fun) end)

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity, session_id, type, body})
      :ok
    end)

    orchestrator_name = Module.concat(__MODULE__, :RunBudgetCapOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-run-budget-cap-1",
                 "issue" => %{
                   "id" => "issue-run-budget-cap-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix budgeted bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:budget_cap_runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:budget_cap_runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)

    assert :ok = Budget.record_usage(db_path, request.run_id, 1.25)

    send(
      pid,
      {:codex_worker_update, "issue-run-budget-cap-1",
       %{
         event: :notification,
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"usage" => %{"total_tokens" => 1}}},
         timestamp: DateTime.utc_now()
       }}
    )

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert {:ok, %{"status" => "failed", "error_code" => "budget_cap"}} = RunLedger.get_run(db_path, request.run_id)
    assert_receive {:linear_activity, "session-run-budget-cap-1", :error, body}, 1_000
    assert body =~ "per-run budget cap"
  end

  test "orchestrator stops an active direct dispatch when shared daily budget is exhausted" do
    db_path = Path.join(System.tmp_dir!(), "surfer-daily-budget-cap-#{System.unique_integer([:positive])}.sqlite3")
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
        codex:
          daily_budget_usd: 1.0
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    parent = self()
    previous_session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_session_activity_fun) end)

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity, session_id, type, body})
      :ok
    end)

    orchestrator_name = Module.concat(__MODULE__, :DailyBudgetCapOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-daily-budget-cap-1",
                 "issue" => %{
                   "id" => "issue-daily-budget-cap-1",
                   "identifier" => "ENG-2",
                   "title" => "Fix shared budgeted bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:daily_budget_cap_runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:daily_budget_cap_runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)

    assert :ok = Budget.record_usage(db_path, request.run_id, 1.25)

    send(
      pid,
      {:codex_worker_update, "issue-daily-budget-cap-1",
       %{
         event: :notification,
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"usage" => %{"total_tokens" => 1}}},
         timestamp: DateTime.utc_now()
       }}
    )

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert {:ok, %{"status" => "failed", "error_code" => "budget_cap"}} = RunLedger.get_run(db_path, request.run_id)
    assert_receive {:linear_activity, "session-daily-budget-cap-1", :error, body}, 1_000
    assert body =~ "daily budget cap"
  end

  test "operator pause cancel mode terminates active direct dispatch runs" do
    previous_pause = Application.get_env(:symphony_elixir, :surfer_runtime_pause)
    on_exit(fn -> restore_app_env(:surfer_runtime_pause, previous_pause) end)
    Application.delete_env(:symphony_elixir, :surfer_runtime_pause)
    previous_session_activity_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_session_activity_fun) end)

    db_path = Path.join(System.tmp_dir!(), "surfer-pause-cancel-#{System.unique_integer([:positive])}.sqlite3")
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

    parent = self()

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_cancel_activity, session_id, type, body})
      :ok
    end)

    orchestrator_name = Module.concat(__MODULE__, :PauseCancelOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-pause-cancel-1",
                 "issue" => %{
                   "id" => "issue-pause-cancel-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    runner_fun = fn _issue, _recipient, _opts ->
      send(parent, {:pause_cancel_runner_started, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:pause_cancel_runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)
    assert %{running: [%{issue_id: "issue-pause-cancel-1"}]} = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert %{paused: true, pause_mode: "cancel", cancelled_running: %{count: 1}} =
             Operator.pause(
               actor: "operator:test",
               reason: "maintenance",
               pause_mode: "cancel",
               cancel_running_server: orchestrator_name
             )

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert {:ok, %{"status" => "cancelled", "error_message" => "maintenance"}} = RunLedger.get_run(db_path, request.run_id)
    assert_receive {:linear_cancel_activity, "session-pause-cancel-1", :error, body}, 1_000
    assert body =~ request.run_id
    assert body =~ "cancelled"
    assert body =~ "maintenance"
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    cancelled_payload = status_transition_payload(events, "cancelled")
    assert cancelled_payload["external_write_status"]["linear"] == "posted"
  end

  test "orchestrator records pending Linear writes when final activity fails" do
    parent = self()
    handler_id = {__MODULE__, self(), :linear_outbox_failure_metrics}

    :telemetry.attach_many(
      handler_id,
      [[:symphony, :surfer, :platform_write_failures]],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-linear-outbox-#{System.unique_integer([:positive])}.sqlite3"
      )

    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    previous_fun = Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun)
    on_exit(fn -> restore_app_env(:surfer_linear_session_activity_fun, previous_fun) end)

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

    Application.put_env(:symphony_elixir, :surfer_linear_session_activity_fun, fn session_id, type, body ->
      send(parent, {:linear_activity_attempt, session_id, type, body})
      {:error, :linear_down}
    end)

    orchestrator_name = Module.concat(__MODULE__, :LinearOutboxOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-1",
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix bug",
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request)

    runner_fun = fn _issue, _recipient, _opts -> :ok end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:linear_activity_attempt, "session-1", :response, _body}, 5_000

    assert_eventually_status(db_path, request.run_id, "completed")
    assert_eventually_event(db_path, request.run_id, "pending_write")
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write" and &1["platform"] == "linear"))

    completed_payload = status_transition_payload(events, "completed")
    assert completed_payload["external_write_status"]["linear"] == "pending"

    assert_receive {:telemetry, [:symphony, :surfer, :platform_write_failures], %{count: 1}, failure_metadata}
    assert failure_metadata.run_id == request.run_id
    assert failure_metadata.platform == "linear"
    assert failure_metadata.external_id == "session-1:response"
    assert failure_metadata.reason == ":linear_down"
  end

  test "orchestrator records pending Discord writes when completion notification fails" do
    parent = self()
    handler_id = {__MODULE__, self(), :discord_outbox_failure_metrics}

    :telemetry.attach_many(
      handler_id,
      [[:symphony, :surfer, :platform_write_failures]],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-discord-outbox-#{System.unique_integer([:positive])}.sqlite3"
      )

    File.rm_rf(db_path)
    on_exit(fn -> File.rm_rf(db_path) end)

    previous_fun = Application.get_env(:symphony_elixir, :surfer_discord_post_fun)
    on_exit(fn -> restore_app_env(:surfer_discord_post_fun, previous_fun) end)

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

    Application.put_env(:symphony_elixir, :surfer_discord_post_fun, fn channel_id, body ->
      send(parent, {:discord_post_attempt, channel_id, body})
      {:error, :discord_down}
    end)

    orchestrator_name = Module.concat(__MODULE__, :DiscordOutboxOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-discord-outbox-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "where is routing handled?"
             })

    assert :ok = RunLedger.initialize(db_path)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    runner_fun = fn _issue, _recipient, _opts -> :ok end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:discord_post_attempt, "channel-1", body}, 5_000
    assert body =~ request.run_id

    assert_eventually_status(db_path, request.run_id, "completed")
    assert_eventually_event(db_path, request.run_id, "pending_write")
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "pending_write" and event["platform"] == "discord" and
               event["external_id"] == "channel-1:channel_message:#{request.run_id}"
           end)

    completed_payload = status_transition_payload(events, "completed")
    assert completed_payload["external_write_status"]["discord"] == "pending"

    assert_receive {:telemetry, [:symphony, :surfer, :platform_write_failures], %{count: 1}, failure_metadata}
    assert failure_metadata.run_id == request.run_id
    assert failure_metadata.platform == "discord"
    assert failure_metadata.external_id == "channel-1:channel_message:#{request.run_id}"
    assert failure_metadata.reason == ":discord_down"
  end

  test "orchestrator can dispatch Discord code questions with a synthetic workspace issue" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :DiscordDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "where is routing handled?"
             })

    runner_fun = fn issue, _recipient, opts ->
      send(parent, {:runner_called, issue, opts})
      :ok
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:runner_called, issue, opts}, 1_000
    assert issue.id == request.run_id
    assert issue.identifier == request.run_id
    assert opts[:surfer_context].source_platform == "discord"
  end

  test "poll reconciliation preserves non-Linear direct dispatch runs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :DiscordReconcileOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-reconcile-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "where is routing handled?"
             })

    runner_fun = fn issue, _recipient, _opts ->
      send(parent, {:discord_runner_started, issue.id, self()})

      receive do
        :release_runner -> :ok
      after
        60_000 -> :ok
      end
    end

    assert :ok = Orchestrator.dispatch_run(orchestrator_name, request, runner_fun: runner_fun)
    assert_receive {:discord_runner_started, run_id, runner_pid}, 1_000
    assert run_id == request.run_id

    assert %{queued: true} = Orchestrator.request_refresh(orchestrator_name)
    Process.sleep(100)

    assert %{running: [%{issue_id: ^run_id}]} = Orchestrator.snapshot(orchestrator_name, 1_000)

    send(runner_pid, :release_runner)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp routed_linear_request!(issue_id, identifier, team_id, repositories) do
    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "agentSession" => %{
                 "id" => "session-#{issue_id}",
                 "issue" => %{
                   "id" => issue_id,
                   "identifier" => identifier,
                   "title" => "Fix #{identifier}",
                   "team" => %{"id" => team_id},
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    assert {:ok, routed} = RunRequest.route(request, repositories)
    routed
  end

  defp discord_request!(message_id) do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => message_id,
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "please fix routing"
             })

    request
  end

  defp assert_eventually_status(db_path, run_id, status, attempts \\ 100)

  defp assert_eventually_status(db_path, run_id, status, attempts) when attempts > 0 do
    case RunLedger.get_run(db_path, run_id) do
      {:ok, %{"status" => ^status}} ->
        :ok

      _ ->
        Process.sleep(25)
        assert_eventually_status(db_path, run_id, status, attempts - 1)
    end
  end

  defp assert_eventually_status(db_path, run_id, status, 0) do
    assert {:ok, %{"status" => ^status}} = RunLedger.get_run(db_path, run_id)
  end

  defp assert_eventually_event(db_path, run_id, event_type, attempts \\ 100)

  defp assert_eventually_event(db_path, run_id, event_type, attempts) when attempts > 0 do
    case RunLedger.list_events(db_path, run_id) do
      {:ok, events} ->
        if Enum.any?(events, &(&1["event_type"] == event_type)) do
          :ok
        else
          Process.sleep(25)
          assert_eventually_event(db_path, run_id, event_type, attempts - 1)
        end

      _ ->
        Process.sleep(25)
        assert_eventually_event(db_path, run_id, event_type, attempts - 1)
    end
  end

  defp assert_eventually_event(db_path, run_id, event_type, 0) do
    assert {:ok, events} = RunLedger.list_events(db_path, run_id)
    assert Enum.any?(events, &(&1["event_type"] == event_type))
  end

  defp status_transition_payload(events, to_status) do
    event =
      Enum.find(events, fn event ->
        event["event_type"] == "status_transition" and
          event["payload_json"] |> Jason.decode!() |> Map.get("to") == to_status
      end)

    assert event
    Jason.decode!(event["payload_json"])
  end
end
