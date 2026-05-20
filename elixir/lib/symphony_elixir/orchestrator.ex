defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Coordinates Surfer direct-dispatch runs and the legacy Symphony Linear poller.

  Surfer v0.1 enters through platform webhooks and calls `dispatch_run/3`. The
  Linear project poller remains available only when workflow polling is
  explicitly enabled.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Surfer.{Budget, Metrics, RunLedger, SecretRedactor, WorkspaceLifecycle}
  alias SymphonyElixir.Surfer.Discord.Notifier, as: DiscordNotifier
  alias SymphonyElixir.Surfer.GitHub.CompanyBrain
  alias SymphonyElixir.Surfer.Linear.Session, as: LinearSession
  alias SymphonyElixir.Surfer.RunRequest

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @company_brain_final_provenance_limit 5
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for direct-dispatch runs and optional polling.
    """

    defstruct [
      :polling_enabled,
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec dispatch_run(GenServer.server(), RunRequest.t(), keyword()) :: :ok | {:error, term()}
  def dispatch_run(server \\ __MODULE__, %RunRequest{} = request, opts \\ []) do
    GenServer.call(server, {:dispatch_run, request, opts})
  end

  @spec cancel_running_runs(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def cancel_running_runs(server \\ __MODULE__, opts \\ []) do
    if Process.whereis(server) do
      GenServer.call(server, {:cancel_running_runs, opts})
    else
      :unavailable
    end
  end

  @spec cancel_run(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :unavailable
  def cancel_run(server \\ __MODULE__, run_id, opts \\ []) when is_binary(run_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:cancel_run, run_id, opts})
    else
      :unavailable
    end
  end

  @impl true
  def init(_opts) do
    config = Config.settings!()

    state = %State{
      polling_enabled: config.polling.enabled,
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup(config)
    state = schedule_tick_if_enabled(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    if state.polling_enabled do
      state = %{
        state
        | poll_check_in_progress: true,
          next_poll_due_at_ms: nil,
          tick_timer_ref: nil,
          tick_token: nil
      }

      notify_dashboard()
      :ok = schedule_poll_cycle_start()
      {:noreply, state}
    else
      {:noreply, clear_poll_schedule(state)}
    end
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    if state.polling_enabled do
      state = %{
        state
        | poll_check_in_progress: true,
          next_poll_due_at_ms: nil,
          tick_timer_ref: nil,
          tick_token: nil
      }

      notify_dashboard()
      :ok = schedule_poll_cycle_start()
      {:noreply, state}
    else
      {:noreply, clear_poll_schedule(state)}
    end
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = if state.polling_enabled, do: maybe_dispatch(state), else: state
    state = schedule_tick_if_enabled(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        running_entry = Map.get(running, issue_id)
        state = complete_running_entry(state, issue_id, running_entry, reason)
        {:noreply, state}
    end
  end

  def handle_info({:direct_dispatch_completed, issue_id, pid}, state) do
    case Map.get(state.running, issue_id) do
      %{pid: ^pid} = running_entry ->
        state = complete_running_entry(state, issue_id, running_entry, :normal, flush_monitor?: true)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:direct_dispatch_failed, issue_id, pid, reason}, state) do
    case Map.get(state.running, issue_id) do
      %{pid: ^pid} = running_entry ->
        state = complete_running_entry(state, issue_id, running_entry, reason, flush_monitor?: true)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
          |> enforce_active_budget_caps(issue_id, updated_running_entry)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = tracker_reconciled_running_ids(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp tracker_reconciled_running_ids(running) when is_map(running) do
    running
    |> Enum.flat_map(fn {issue_id, running_entry} ->
      if tracker_reconciled_running_entry?(issue_id, running_entry), do: [issue_id], else: []
    end)
  end

  defp tracker_reconciled_running_ids(_running), do: []

  defp tracker_reconciled_running_entry?(_issue_id, running_entry) when is_map(running_entry) do
    Map.get(running_entry, :dispatch_kind, :poller) == :poller
  end

  defp tracker_reconciled_running_entry?(_issue_id, _running_entry), do: false

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        reconcile_stalled_running_issues(state, config.codex.stall_timeout_ms)

      {:error, reason} ->
        Logger.debug("Skipping stalled issue reconciliation because config is unavailable: #{safe_inspect(reason)}")
        state
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state, timeout_ms) do
    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp complete_running_entry(state, issue_id, running_entry, reason, opts \\ []) do
    state = %{state | running: Map.delete(state.running, issue_id)}
    state = maybe_flush_monitor(state, running_entry, opts)
    state = record_session_completion_totals(state, running_entry)
    session_id = running_entry_session_id(running_entry)
    run_context = running_entry_run_context(running_entry)

    state =
      case normalize_task_exit_reason(reason) do
        :normal ->
          post_surfer_completion(running_entry, :normal)

          Logger.info("Agent task completed for issue_id=#{issue_id}#{run_context} session_id=#{session_id}; scheduling active-state continuation check")

          state
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :continuation,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_id: running_entry_run_id(running_entry)
          })

        :error ->
          post_surfer_completion(running_entry, reason)
          safe_reason = safe_inspect(reason)

          Logger.warning("Agent task exited for issue_id=#{issue_id}#{run_context} session_id=#{session_id} reason=#{safe_reason}; scheduling retry")

          next_attempt = next_retry_attempt_from_running(running_entry)

          schedule_issue_retry(state, issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "agent exited: #{safe_reason}",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_id: running_entry_run_id(running_entry)
          })
      end

    emit_codex_run_duration(running_entry)
    emit_runtime_gauges(state)
    Logger.info("Agent task finished for issue_id=#{issue_id}#{run_context} session_id=#{session_id} reason=#{safe_inspect(reason)}")

    notify_dashboard()
    state
  end

  defp maybe_flush_monitor(state, %{ref: ref}, opts) when is_reference(ref) do
    if Keyword.get(opts, :flush_monitor?, false) do
      Process.demonitor(ref, [:flush])
    end

    state
  end

  defp maybe_flush_monitor(state, _running_entry, _opts), do: state

  defp post_surfer_completion(running_entry, reason) when is_map(running_entry) do
    session_id = Map.get(running_entry, :session_id)
    surfer_context = Map.get(running_entry, :surfer_context, %{})
    run_id = Map.get(surfer_context, :run_id) || Map.get(surfer_context, "run_id")

    case reason do
      :normal ->
        body = final_status_body("Surfer run #{run_id} completed.", surfer_context)
        linear_status = post_linear_session_activity(running_entry, session_id, :response, body)
        discord_status = post_discord_status(running_entry, surfer_context, body)

        record_surfer_status(running_entry, "completed",
          reason: "runner completed",
          actor: "surfer",
          external_write_status: external_write_status(linear: linear_status, discord: discord_status)
        )

      _ ->
        safe_reason = safe_inspect(reason)
        body = final_status_body("Surfer run #{run_id} failed: #{safe_reason}", surfer_context)
        linear_status = post_linear_session_activity(running_entry, session_id, :error, body)
        discord_status = post_discord_status(running_entry, surfer_context, body)

        record_surfer_status(running_entry, "failed",
          reason: "runner failed",
          actor: "surfer",
          error_message: safe_reason,
          external_write_status: external_write_status(linear: linear_status, discord: discord_status)
        )
    end
  end

  defp post_surfer_completion(_running_entry, _reason), do: :ok

  defp final_status_body(base_body, surfer_context) when is_binary(base_body) do
    case company_brain_provenance_lines(surfer_context) do
      [] ->
        base_body

      lines ->
        base_body <>
          "\n\nCompany Brain context used (background only; not authoritative):\n" <>
          Enum.join(lines, "\n")
    end
  end

  defp company_brain_provenance_lines(surfer_context) do
    refs =
      case context_value(surfer_context, :company_brain_refs) do
        refs when is_list(refs) -> refs
        _other -> []
      end

    total_count = length(refs)

    lines =
      refs
      |> Enum.take(@company_brain_final_provenance_limit)
      |> Enum.map(&company_brain_provenance_line/1)
      |> Enum.reject(&is_nil/1)

    cond do
      lines == [] ->
        []

      total_count > @company_brain_final_provenance_limit ->
        lines ++ ["- #{total_count - @company_brain_final_provenance_limit} more Company Brain refs omitted"]

      true ->
        lines
    end
  end

  defp company_brain_provenance_line(ref) when is_map(ref) do
    repo = context_value(ref, :repo)
    path = context_value(ref, :path)
    url = context_value(ref, :url)

    label =
      cond do
        is_binary(repo) and is_binary(path) -> "#{repo}:#{path}"
        is_binary(path) -> path
        is_binary(url) -> url
        true -> nil
      end

    if is_binary(label) do
      url_suffix = if is_binary(url) and url != label, do: " (#{url})", else: ""
      SecretRedactor.redact_text("- #{label}#{url_suffix}")
    end
  end

  defp company_brain_provenance_line(_ref), do: nil

  defp post_surfer_cancelled(running_entry, reason) when is_map(running_entry) do
    run_id = running_entry_run_id(running_entry)
    body = "Surfer run #{run_id} cancelled: #{to_string(reason)}"
    session_id = Map.get(running_entry, :session_id)
    surfer_context = Map.get(running_entry, :surfer_context, %{})

    linear_status = post_linear_session_activity(running_entry, session_id, :error, body)
    discord_status = post_discord_status(running_entry, surfer_context, body)

    external_write_status(linear: linear_status, discord: discord_status)
  end

  defp post_surfer_cancelled(_running_entry, _reason), do: %{}

  defp post_budget_cap_failure(running_entry, scope, metadata) when is_map(running_entry) do
    run_id = running_entry_run_id(running_entry)
    scope_label = budget_cap_scope_label(scope)
    body = "Surfer run #{run_id} failed: #{scope_label} budget cap exceeded."
    session_id = Map.get(running_entry, :session_id)
    surfer_context = Map.get(running_entry, :surfer_context, %{})

    linear_status = post_linear_session_activity(running_entry, session_id, :error, body)
    discord_status = post_discord_status(running_entry, surfer_context, body)

    Logger.warning("Surfer run exceeded #{scope_label} budget cap run_id=#{run_id} used_usd=#{inspect(Map.get(metadata, :used_usd))} limit_usd=#{inspect(Map.get(metadata, :limit_usd))}")

    external_write_status(linear: linear_status, discord: discord_status)
  end

  defp budget_cap_scope_label(:daily), do: "daily"
  defp budget_cap_scope_label(_scope), do: "per-run"

  defp normalize_task_exit_reason(:normal), do: :normal
  defp normalize_task_exit_reason(:noproc), do: :normal
  defp normalize_task_exit_reason(_reason), do: :error

  defp post_linear_session_activity(running_entry, session_id, type, body)
       when is_binary(session_id) and is_atom(type) and is_binary(body) do
    result =
      case Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun) do
        fun when is_function(fun, 3) ->
          fun.(session_id, type, body)

        _ ->
          case type do
            :response -> LinearSession.final_response(session_id, body)
            :error -> LinearSession.error(session_id, body)
          end
      end

    maybe_record_pending_linear_write(result, running_entry, session_id, type, body)
  end

  defp post_linear_session_activity(_running_entry, _session_id, _type, _body), do: :skipped

  defp maybe_record_pending_linear_write(:ok, _running_entry, _session_id, _type, _body), do: :posted

  defp maybe_record_pending_linear_write({:error, reason}, running_entry, session_id, type, body) do
    payload = %{
      session_id: session_id,
      type: to_string(type),
      body: body,
      error: inspect(reason)
    }

    record_pending_platform_write(running_entry, "linear", "#{session_id}:#{type}", payload)
    :pending
  end

  defp maybe_record_pending_linear_write(_result, _running_entry, _session_id, _type, _body), do: :unknown

  defp post_discord_status(running_entry, %{source_platform: "discord", discord: %{channel_id: channel_id}}, body)
       when is_binary(channel_id) do
    channel_id
    |> post_discord_message(body)
    |> maybe_record_pending_discord_write(running_entry, channel_id, body)
  end

  defp post_discord_status(running_entry, %{"source_platform" => "discord", "discord" => %{"channel_id" => channel_id}}, body)
       when is_binary(channel_id) do
    channel_id
    |> post_discord_message(body)
    |> maybe_record_pending_discord_write(running_entry, channel_id, body)
  end

  defp post_discord_status(_running_entry, _surfer_context, _body), do: :skipped

  defp post_discord_message(channel_id, body) do
    case Application.get_env(:symphony_elixir, :surfer_discord_post_fun) do
      fun when is_function(fun, 2) ->
        fun.(channel_id, body)

      _ ->
        DiscordNotifier.post_message(channel_id, body, bot_token: Config.settings!().surfer.platforms.discord.bot_token)
    end
  end

  defp maybe_record_pending_discord_write(:ok, _running_entry, _channel_id, _body), do: :posted

  defp maybe_record_pending_discord_write({:error, reason}, running_entry, channel_id, body) do
    payload = %{
      type: "channel_message",
      channel_id: channel_id,
      body: body,
      error: inspect(reason)
    }

    run_id = running_entry_run_id(running_entry)
    external_id = Enum.join([channel_id, "channel_message", run_id], ":")

    record_pending_platform_write(running_entry, "discord", external_id, payload)
    :pending
  end

  defp maybe_record_pending_discord_write(_result, _running_entry, _channel_id, _body) do
    :unknown
  end

  defp external_write_status(statuses) do
    statuses
    |> Enum.reject(fn {_platform, status} -> status == :skipped end)
    |> Map.new(fn {platform, status} -> {platform, to_string(status)} end)
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    run_id = pick_retry_run_id(previous_retry, metadata)
    run_context = run_context(run_id)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id}#{run_context} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            run_id: run_id
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup(config) do
    run_legacy_terminal_workspace_cleanup(config)
    run_surfer_workspace_retention_cleanup(config)
    run_surfer_ledger_retention_prune(config)
  end

  defp run_legacy_terminal_workspace_cleanup(config) do
    case Tracker.fetch_issues_by_states(config.tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp run_surfer_workspace_retention_cleanup(config) do
    storage = config.surfer.storage
    db_path = storage.sqlite_path
    workspace_root = config.surfer.workspace_root || config.workspace.root

    cond do
      not populated_path?(db_path) or not File.exists?(db_path) ->
        :ok

      not populated_path?(workspace_root) ->
        :ok

      true ->
        case WorkspaceLifecycle.cleanup(workspace_root, db_path,
               successful_ttl_days: storage.workspace_retention_days,
               failed_ttl_days: 30
             ) do
          {:ok, _summary} ->
            :ok

          {:error, reason} ->
            Logger.warning("Skipping Surfer startup workspace retention cleanup: #{inspect(reason)}")
        end
    end
  end

  defp run_surfer_ledger_retention_prune(config) do
    storage = config.surfer.storage
    db_path = storage.sqlite_path
    retention_days = storage.retention_days

    cond do
      not populated_path?(db_path) or not File.exists?(db_path) ->
        :ok

      not is_integer(retention_days) or retention_days <= 0 ->
        :ok

      true ->
        cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

        case RunLedger.prune_before(db_path, cutoff) do
          {:ok, _summary} ->
            :ok

          {:error, reason} ->
            Logger.warning("Skipping Surfer ledger retention prune: #{inspect(reason)}")
        end
    end
  end

  defp populated_path?(path) when is_binary(path), do: String.trim(path) != ""
  defp populated_path?(_path), do: false

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_retry_backoff_ms())
  end

  defp max_retry_backoff_ms do
    case Config.settings() do
      {:ok, config} -> config.agent.max_retry_backoff_ms
      {:error, _reason} -> 300_000
    end
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_run_id(previous_retry, metadata) do
    metadata[:run_id] || Map.get(previous_retry, :run_id)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp running_entry_run_context(running_entry) do
    running_entry
    |> running_entry_run_id()
    |> run_context()
  end

  defp running_entry_run_id(%{surfer_context: surfer_context}), do: run_id_from_context(surfer_context)
  defp running_entry_run_id(_running_entry), do: nil

  defp run_context(run_id) when is_binary(run_id) and run_id != "", do: " run_id=#{run_id}"
  defp run_context(_run_id), do: ""

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:cancel_running_runs, opts}, _from, state) do
    reason = Keyword.get(opts, :reason, "Surfer paused")
    actor = Keyword.get(opts, :actor, "operator")

    {cancelled, state} =
      state.running
      |> Map.keys()
      |> Enum.reduce({[], state}, fn issue_id, {cancelled_acc, state_acc} ->
        cancel_running_issue(state_acc, issue_id, reason, actor, cancelled_acc)
      end)

    emit_runtime_gauges(state)
    notify_dashboard()

    {:reply, {:ok, %{count: length(cancelled), runs: Enum.reverse(cancelled)}}, state}
  end

  def handle_call({:cancel_run, run_id, opts}, _from, state) do
    reason = Keyword.get(opts, :reason, "cancelled by operator")
    actor = Keyword.get(opts, :actor, "operator")

    case running_issue_id_for_run_id(state.running, run_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      issue_id ->
        {[cancelled], state} =
          cancel_running_issue(state, issue_id, reason, actor, [], record_status: Keyword.get(opts, :record_status, true))

        emit_runtime_gauges(state)
        notify_dashboard()

        {:reply, {:ok, cancelled}, state}
    end
  end

  def handle_call({:dispatch_run, %RunRequest{} = request, opts}, from, state) do
    runner_fun = Keyword.get(opts, :runner_fun, &AgentRunner.run/3)
    request = attach_company_brain_refs(request)
    issue = request_issue(request)
    recipient = self()
    surfer_context = RunRequest.surfer_context(request)

    cond do
      direct_issue_already_claimed?(state, request, issue) ->
        record_direct_dispatch_blocked(request, "awaiting_input",
          reason: "already claimed linear issue",
          actor: "surfer",
          error_code: "already_claimed",
          error_message: "Linear issue #{issue.id} already has an active Surfer run"
        )

        {:reply, {:error, {:already_claimed, issue.id}}, state}

      repository_write_busy?(state, request) ->
        repository_key = repository_key(request.routing)

        record_direct_dispatch_blocked(request, "awaiting_input",
          reason: "repository busy",
          actor: "surfer",
          error_code: "repository_busy",
          error_message: "Repository #{repository_key} already has an active write Surfer run"
        )

        {:reply, {:error, {:repository_busy, repository_key}}, state}

      true ->
        case record_direct_dispatch_started(request) do
          :ok ->
            start_direct_dispatch_worker(state, from, request, issue, recipient, surfer_context, runner_fun)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         enabled?: state.polling_enabled,
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    state = refresh_runtime_config(state)
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    if state.polling_enabled do
      state = if coalesced, do: state, else: schedule_tick(state, 0)

      {:reply,
       %{
         queued: true,
         coalesced: coalesced,
         requested_at: DateTime.utc_now(),
         operations: ["poll", "reconcile"]
       }, state}
    else
      {:reply,
       %{
         queued: false,
         coalesced: false,
         requested_at: DateTime.utc_now(),
         operations: [],
         reason: :polling_disabled
       }, clear_poll_schedule(state)}
    end
  end

  defp start_direct_dispatch_worker(state, from, request, issue, recipient, surfer_context, runner_fun) do
    start_token = make_ref()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           receive do
             {:run_direct_dispatch, ^start_token} ->
               run_and_report_direct_dispatch(runner_fun, issue, recipient, request, surfer_context)
           end
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Logger.info("Dispatching Surfer run to agent: run_id=#{request.run_id} issue_id=#{issue.id} source_platform=#{request.source.platform}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: nil,
            workspace_path: nil,
            session_id: request.lineage.linear[:agent_session_id],
            surfer_context: surfer_context,
            dispatch_kind: :direct,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: nil,
            started_at: DateTime.utc_now()
          })

        state = %{state | running: running, claimed: MapSet.put(state.claimed, issue.id)}
        send(pid, {:run_direct_dispatch, start_token})
        GenServer.reply(from, :ok)
        emit_runtime_gauges(state)
        notify_dashboard()
        {:noreply, state}

      {:error, reason} ->
        record_surfer_status(request, "failed",
          reason: "failed to spawn runner",
          actor: "surfer",
          error_message: inspect(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  defp run_and_report_direct_dispatch(runner_fun, issue, recipient, request, surfer_context) do
    case run_direct_dispatch_runner(runner_fun, issue, recipient, request, surfer_context) do
      {:ok, result} ->
        send(recipient, {:direct_dispatch_completed, issue.id, self()})
        result

      {:error, reason} ->
        send(recipient, {:direct_dispatch_failed, issue.id, self(), reason})
        :ok
    end
  end

  defp run_direct_dispatch_runner(runner_fun, issue, recipient, request, surfer_context) do
    result =
      try do
        {:ok,
         runner_fun.(issue, recipient,
           surfer_context: surfer_context,
           workspace_identifier: surfer_workspace_identifier(request)
         )}
      rescue
        exception -> {:error, {exception.__struct__, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    result
  end

  defp attach_company_brain_refs(%RunRequest{} = request) do
    github = Config.settings!().surfer.platforms.github
    paths = configured_company_brain_paths(request, github)
    fetch_fun = Application.get_env(:symphony_elixir, :surfer_company_brain_fetch_fun)
    maybe_attach_company_brain_refs(request, github, paths, fetch_fun)
  end

  defp maybe_attach_company_brain_refs(%RunRequest{} = request, _github, [], _fetch_fun), do: request

  defp maybe_attach_company_brain_refs(%RunRequest{} = request, github, paths, fetch_fun) do
    config = %{
      company_brain_repo: Map.get(github, :company_brain_repo),
      company_brain_paths: paths,
      fetch_fun: fetch_fun
    }

    case CompanyBrain.retrieve(config) do
      {:ok, []} ->
        request

      {:ok, refs} ->
        context = request.context || %{}
        %{request | context: Map.put(context, :company_brain_refs, refs)}

      {:error, reason} ->
        Logger.warning("Failed to retrieve Surfer Company Brain context run_id=#{request.run_id}: #{safe_inspect(reason)}")
        request
    end
  end

  defp configured_company_brain_paths(%RunRequest{} = request, _github) do
    request.routing
    |> Map.get(:company_brain_paths)
    |> normalize_company_brain_paths()
  end

  defp normalize_company_brain_paths(paths) when is_list(paths), do: Enum.filter(paths, &is_binary/1)
  defp normalize_company_brain_paths(_paths), do: []

  defp request_issue(%RunRequest{issue: %Issue{} = issue}), do: issue

  defp request_issue(%RunRequest{} = request) do
    %Issue{
      id: request.run_id,
      identifier: request.run_id,
      title: request.request.title || "Surfer request",
      description: request.request.body,
      state: "Surfer",
      labels: []
    }
  end

  defp surfer_workspace_identifier(%RunRequest{} = request) do
    repository_slug =
      request.routing
      |> repository_key()
      |> case do
        repository_key when is_binary(repository_key) and repository_key != "" ->
          repository_key

        _ ->
          "unrouted"
      end

    [repository_slug, request.run_id]
  end

  defp running_issue_id_for_run_id(running, run_id) when is_map(running) and is_binary(run_id) do
    Enum.find_value(running, fn {issue_id, running_entry} ->
      cond do
        issue_id == run_id -> issue_id
        running_entry_run_id(running_entry) == run_id -> issue_id
        true -> nil
      end
    end)
  end

  defp running_issue_id_for_run_id(_running, _run_id), do: nil

  defp cancel_running_issue(%State{} = state, issue_id, reason, actor, cancelled_acc, opts \\ []) do
    running_entry = Map.get(state.running, issue_id)
    run_id = running_entry_run_id(running_entry)

    if Keyword.get(opts, :record_status, true) do
      external_write_status = post_surfer_cancelled(running_entry, reason)

      record_surfer_status(running_entry, "cancelled",
        reason: "operator pause",
        actor: actor,
        error_message: reason,
        external_write_status: external_write_status
      )
    end

    cancelled =
      %{
        issue_id: issue_id,
        run_id: run_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {[cancelled | cancelled_acc], terminate_running_issue(state, issue_id, false)}
  end

  defp direct_issue_already_claimed?(%State{} = state, %RunRequest{} = request, %Issue{id: issue_id})
       when is_binary(issue_id) do
    MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id) or
      ledger_linear_issue_claimed?(request, issue_id)
  end

  defp direct_issue_already_claimed?(_state, _request, _issue), do: false

  defp ledger_linear_issue_claimed?(%RunRequest{run_id: run_id, lineage: %{linear: linear}}, issue_id)
       when is_map(linear) and is_binary(issue_id) do
    linear_issue_matches?(linear, issue_id) and ledger_has_open_linear_issue_run?(issue_id, run_id)
  end

  defp ledger_linear_issue_claimed?(_request, _issue_id), do: false

  defp linear_issue_matches?(linear, issue_id) when is_map(linear) do
    linear[:issue_id] == issue_id or linear["issue_id"] == issue_id
  end

  defp ledger_has_open_linear_issue_run?(issue_id, run_id) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        count_open_linear_issue_runs(db_path, issue_id, run_id)

      :disabled ->
        false
    end
  end

  defp count_open_linear_issue_runs(db_path, issue_id, run_id) do
    case RunLedger.count_open_linear_issue_runs(db_path, issue_id, exclude_run_id: run_id) do
      {:ok, count} when count > 0 ->
        true

      {:ok, _count} ->
        false

      {:error, reason} ->
        Logger.warning("Unable to check Surfer ledger claim run_id=#{run_id} linear_issue_id=#{issue_id}: #{safe_inspect(reason)}")
        false
    end
  end

  defp repository_write_busy?(%State{} = state, %RunRequest{} = request) do
    with true <- write_run?(request.request.mode),
         repository_key when is_binary(repository_key) <- repository_key(request.routing) do
      Enum.any?(state.running, fn {_issue_id, running_entry} ->
        running_entry
        |> Map.get(:surfer_context, %{})
        |> same_write_repository?(repository_key)
      end)
    else
      _ -> false
    end
  end

  defp write_run?(mode) when mode in [:durable_task, :issue_create, "durable_task", "issue_create"], do: true
  defp write_run?(_mode), do: false

  defp same_write_repository?(%{request_mode: mode, routing: routing}, repository_key) do
    write_run?(mode) and repository_key(routing) == repository_key
  end

  defp same_write_repository?(%{"request_mode" => mode, "routing" => routing}, repository_key) do
    write_run?(mode) and repository_key(routing) == repository_key
  end

  defp same_write_repository?(_context, _repository_key), do: false

  defp repository_key(routing) when is_map(routing) do
    Map.get(routing, :repository_key) || Map.get(routing, "repository_key") || Map.get(routing, :repository) || Map.get(routing, "repository")
  end

  defp repository_key(_routing), do: nil

  defp record_direct_dispatch_started(%RunRequest{} = request) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        with :ok <- RunLedger.initialize(db_path),
             :ok <- RunLedger.upsert_run(db_path, request, status: "queued") do
          RunLedger.update_status(db_path, request.run_id, "running",
            reason: "direct dispatch accepted",
            actor: "surfer"
          )
        end

      :disabled ->
        :ok
    end
  end

  defp record_direct_dispatch_blocked(%RunRequest{} = request, status, opts) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        result =
          with :ok <- RunLedger.initialize(db_path),
               :ok <- RunLedger.upsert_run(db_path, request, status: "queued") do
            RunLedger.update_status(db_path, request.run_id, status, opts)
          end

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record blocked Surfer dispatch run_id=#{request.run_id} status=#{status}: #{inspect(reason)}")

            :ok
        end

      :disabled ->
        :ok
    end
  end

  defp emit_runtime_gauges(%State{} = state) do
    metadata = %{source: :orchestrator}
    Metrics.emit(:running_runs, %{count: map_size(state.running)}, metadata)
    Metrics.emit(:queued_runs, %{count: map_size(state.retry_attempts)}, metadata)
  end

  defp emit_codex_run_duration(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :started_at) do
      %DateTime{} = started_at ->
        duration_ms =
          started_at
          |> DateTime.diff(DateTime.utc_now(), :millisecond)
          |> abs()

        metadata =
          running_entry
          |> Map.get(:surfer_context, %{})
          |> run_id_from_context()
          |> case do
            run_id when is_binary(run_id) -> %{run_id: run_id}
            _ -> %{}
          end

        Metrics.emit(:codex_run_ms, %{duration_ms: duration_ms}, metadata)

      _ ->
        :ok
    end
  end

  defp record_surfer_status(%RunRequest{} = request, status, opts) do
    update_surfer_run_status(request.run_id, status, opts)
  end

  defp record_surfer_status(running_entry, status, opts) when is_map(running_entry) do
    running_entry
    |> Map.get(:surfer_context, %{})
    |> run_id_from_context()
    |> update_surfer_run_status(status, opts)
  end

  defp update_surfer_run_status(nil, _status, _opts), do: :ok

  defp update_surfer_run_status(run_id, status, opts) when is_binary(run_id) do
    case surfer_ledger_path() do
      {:ok, db_path} ->
        case RunLedger.update_status(db_path, run_id, status, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to update Surfer run ledger status run_id=#{run_id} status=#{status}: #{inspect(reason)}")
            :ok
        end

      :disabled ->
        :ok
    end
  end

  defp record_pending_platform_write(running_entry, platform, external_id, payload) do
    run_id =
      running_entry
      |> Map.get(:surfer_context, %{})
      |> run_id_from_context()

    emit_pending_platform_write_failure(run_id, platform, external_id, payload)

    case {run_id, surfer_ledger_path()} do
      {run_id, {:ok, db_path}} when is_binary(run_id) ->
        case RunLedger.record_pending_write(db_path, run_id, %{
               platform: platform,
               external_id: external_id,
               idempotency_hash: RunLedger.pending_write_idempotency_hash(payload),
               payload: payload
             }) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record pending platform write run_id=#{run_id} platform=#{platform}: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp emit_pending_platform_write_failure(run_id, platform, external_id, payload) do
    metadata =
      %{
        run_id: run_id,
        platform: platform,
        external_id: external_id,
        reason: payload_error(payload)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Metrics.emit(:platform_write_failures, %{count: 1}, metadata)
  end

  defp payload_error(payload) when is_map(payload) do
    Map.get(payload, :error) || Map.get(payload, "error")
  end

  defp context_value(context, key), do: Map.get(context, key) || Map.get(context, to_string(key))

  defp run_id_from_context(%{run_id: run_id}), do: run_id
  defp run_id_from_context(%{"run_id" => run_id}), do: run_id
  defp run_id_from_context(_context), do: nil

  defp surfer_ledger_path do
    case Config.settings() do
      {:ok, settings} ->
        ledger_path(settings.surfer.storage.sqlite_path)

      {:error, reason} ->
        Logger.debug("Skipping Surfer ledger write because config is unavailable: #{inspect(reason)}")
        :disabled
    end
  end

  defp ledger_path(path) when is_binary(path) do
    if String.trim(path) == "", do: :disabled, else: {:ok, path}
  end

  defp ledger_path(_path), do: :disabled

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_tick_if_enabled(%State{polling_enabled: true} = state, delay_ms), do: schedule_tick(state, delay_ms)
  defp schedule_tick_if_enabled(%State{} = state, _delay_ms), do: clear_poll_schedule(state)

  defp clear_poll_schedule(%State{} = state) do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    %{state | poll_check_in_progress: false, next_poll_due_at_ms: nil, tick_timer_ref: nil, tick_token: nil}
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        %{
          state
          | polling_enabled: config.polling.enabled,
            poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: config.agent.max_concurrent_agents
        }
        |> maybe_clear_disabled_polling()

      {:error, reason} ->
        Logger.debug("Skipping orchestrator runtime config refresh: #{inspect(reason)}")
        state
    end
  end

  defp maybe_clear_disabled_polling(%State{polling_enabled: false} = state), do: clear_poll_schedule(state)
  defp maybe_clear_disabled_polling(%State{} = state), do: state

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp safe_inspect(reason) do
    reason
    |> SecretRedactor.redact()
    |> inspect()
    |> SecretRedactor.redact_text()
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp enforce_active_budget_caps(%State{} = state, issue_id, running_entry) do
    with run_id when is_binary(run_id) <- running_entry_run_id(running_entry),
         {:ok, db_path} <- surfer_ledger_path(),
         {run_limit_usd, daily_limit_usd} <- budget_limits() do
      case active_budget_cap_result(db_path, run_id, run_limit_usd, daily_limit_usd) do
        {:exceeded, scope, metadata} ->
          mark_daily_budget_cap_failed(scope, running_entry)
          post_budget_cap_failure(running_entry, scope, metadata)
          emit_codex_run_duration(running_entry)
          state = terminate_running_issue(state, issue_id, false)
          emit_runtime_gauges(state)
          state

        :ok ->
          state

        {:error, reason} ->
          Logger.warning("Skipping Surfer budget cap check: #{inspect(reason)}")
          state
      end
    else
      _ ->
        state
    end
  end

  defp active_budget_cap_result(db_path, run_id, run_limit_usd, daily_limit_usd) do
    with :ok <- Budget.check_run_cap(db_path, run_id, run_limit_usd),
         :ok <- Budget.check_daily_cap(db_path, daily_limit_usd) do
      :ok
    else
      {:error, {:run_budget_cap_exceeded, metadata}} -> {:exceeded, :run, metadata}
      {:error, {:daily_budget_cap_exceeded, metadata}} -> {:exceeded, :daily, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_daily_budget_cap_failed(:daily, running_entry) do
    record_surfer_status(running_entry, "failed",
      reason: "daily budget cap exceeded",
      actor: "surfer",
      error_code: "budget_cap",
      error_message: "Daily Codex budget cap exceeded"
    )
  end

  defp mark_daily_budget_cap_failed(_scope, _running_entry), do: :ok

  defp budget_limits do
    case Config.settings() do
      {:ok, settings} -> {settings.surfer.codex.per_run_budget_usd, settings.surfer.codex.daily_budget_usd}
      {:error, _reason} -> {nil, nil}
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
