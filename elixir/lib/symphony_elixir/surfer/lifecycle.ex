defmodule SymphonyElixir.Surfer.Lifecycle do
  @moduledoc """
  Operator lifecycle controls for locally-ledgered Surfer runs.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Surfer.Discord.Notifier, as: DiscordNotifier
  alias SymphonyElixir.Surfer.Linear.Session
  alias SymphonyElixir.Surfer.{Metrics, RunLedger, RunRequest, SecretRedactor}

  @linear_lineage_keys ~w(issue_id issue_identifier team_id agent_session_id comment_id agent_activity_id)
  @discord_lineage_keys ~w(guild_id channel_id thread_id message_id interaction_id application_id)
  @github_lineage_keys ~w(repo pull_request_number)
  @routing_keys ~w(repository repository_key repository_full_name repository_url checkout_path workflow_path branch_hint confidence reason company_brain_paths)

  @spec cancel(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def cancel(db_path, run_id, opts \\ []) when is_binary(run_id) do
    reason = Keyword.get(opts, :reason, "cancelled by operator")

    with {:ok, run} <- RunLedger.get_run(db_path, run_id),
         :ok <- RunLedger.validate_status_transition(db_path, run_id, "cancelled") do
      write_status =
        if Keyword.get(opts, :notify_source?, true) do
          report_cancelled_to_source(db_path, run, reason)
        else
          %{}
        end

      RunLedger.update_status(db_path, run_id, "cancelled",
        reason: reason,
        actor: Keyword.get(opts, :actor, "operator"),
        external_write_status: write_status
      )
    end
  end

  defp report_cancelled_to_source(db_path, %{"id" => run_id, "source_platform" => "linear"} = run, reason) do
    session_id = Map.get(run, "linear_agent_session_id")
    body = cancellation_body(run_id, reason)

    case present_string(session_id) do
      {:ok, session_id} ->
        %{linear: post_linear_cancellation(db_path, run_id, session_id, body)}

      :error ->
        %{}
    end
  end

  defp report_cancelled_to_source(db_path, %{"id" => run_id, "source_platform" => "discord"} = run, reason) do
    channel_id = Map.get(run, "discord_channel_id")
    body = cancellation_body(run_id, reason)

    case present_string(channel_id) do
      {:ok, channel_id} ->
        %{discord: post_discord_cancellation(db_path, run_id, channel_id, body)}

      :error ->
        %{}
    end
  end

  defp report_cancelled_to_source(_db_path, _run, _reason), do: %{}

  defp cancellation_body(run_id, reason), do: "Surfer run #{run_id} cancelled: #{to_string(reason)}"

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present_string(_value), do: :error

  defp post_linear_cancellation(db_path, run_id, session_id, body) do
    case call_linear_activity(session_id, :error, body) do
      :ok ->
        "posted"

      {:error, reason} ->
        record_pending_linear_activity_write(db_path, run_id, session_id, :error, body, reason)
        "pending"

      other ->
        reason = {:unexpected_linear_activity_result, other}
        record_pending_linear_activity_write(db_path, run_id, session_id, :error, body, reason)
        "pending"
    end
  end

  defp call_linear_activity(session_id, type, body) when is_atom(type) and is_binary(body) do
    case Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun) do
      fun when is_function(fun, 3) ->
        fun.(session_id, type, body)

      _ ->
        case type do
          :error -> Session.error(session_id, body)
        end
    end
  end

  defp record_pending_linear_activity_write(db_path, run_id, session_id, type, body, reason) do
    external_id = "#{session_id}:#{type}:#{run_id}"

    payload = %{
      type: to_string(type),
      session_id: session_id,
      body: body,
      error: safe_inspect(reason)
    }

    record_pending_platform_write(db_path, run_id, "linear", external_id, payload, reason)
  end

  defp post_discord_cancellation(db_path, run_id, channel_id, body) do
    case call_discord_message(channel_id, body) do
      :ok ->
        "posted"

      {:error, reason} ->
        record_pending_discord_channel_write(db_path, run_id, channel_id, body, reason)
        "pending"

      other ->
        reason = {:unexpected_discord_message_result, other}
        record_pending_discord_channel_write(db_path, run_id, channel_id, body, reason)
        "pending"
    end
  end

  defp call_discord_message(channel_id, body) do
    case Application.get_env(:symphony_elixir, :surfer_discord_post_fun) do
      fun when is_function(fun, 2) ->
        fun.(channel_id, body)

      _ ->
        DiscordNotifier.post_message(channel_id, body, bot_token: Config.settings!().surfer.platforms.discord.bot_token)
    end
  end

  defp record_pending_discord_channel_write(db_path, run_id, channel_id, body, reason) do
    external_id = "#{channel_id}:channel_message:#{run_id}"

    payload = %{
      type: "channel_message",
      channel_id: channel_id,
      body: body,
      error: safe_inspect(reason)
    }

    record_pending_platform_write(db_path, run_id, "discord", external_id, payload, reason)
  end

  defp record_pending_platform_write(db_path, run_id, platform, external_id, payload, reason) do
    Metrics.emit(:platform_write_failures, %{count: 1}, %{
      run_id: run_id,
      platform: platform,
      external_id: external_id,
      reason: safe_inspect(reason)
    })

    case RunLedger.record_pending_write(db_path, run_id, %{
           platform: platform,
           external_id: external_id,
           idempotency_hash: idempotency_hash(payload),
           payload: payload
         }) do
      :ok -> :ok
      {:error, pending_reason} -> Logger.warning("Failed to record pending cancellation write run_id=#{run_id} platform=#{platform}: #{safe_inspect(pending_reason)}")
    end
  end

  @spec takeover(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def takeover(db_path, run_id, opts \\ []) when is_binary(run_id) do
    actor = Keyword.get(opts, :actor, "operator")
    reason = Keyword.get(opts, :reason, "taken over by operator")

    with {:ok, handoff_status} <- takeover_handoff_status(db_path, run_id),
         :ok <-
           RunLedger.update_status(db_path, run_id, handoff_status,
             reason: reason,
             actor: actor
           ) do
      RunLedger.record_event(db_path, run_id, %{
        event_type: "handoff_note",
        platform: "surfer",
        payload: %{
          actor: actor,
          reason: reason,
          status: handoff_status,
          handoff_to: "human",
          note: Keyword.get(opts, :note, "Surfer run #{run_id} was taken over by #{actor}: #{reason}")
        }
      })
    end
  end

  defp takeover_handoff_status(db_path, run_id) do
    case RunLedger.validate_status_transition(db_path, run_id, "awaiting_review") do
      :ok ->
        {:ok, "awaiting_review"}

      {:error, {:invalid_transition, _from, "awaiting_review"}} ->
        case RunLedger.validate_status_transition(db_path, run_id, "cancelled") do
          :ok -> {:ok, "cancelled"}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec record_github_pr_opened(Path.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def record_github_pr_opened(db_path, run_id, pr, opts \\ [])
      when is_binary(db_path) and is_binary(run_id) and is_map(pr) do
    with {:ok, pr_context} <- normalize_github_pr(pr),
         :ok <-
           RunLedger.record_link(db_path, run_id, %{
             platform: "github",
             kind: "pull_request",
             external_id: pr_context.external_id,
             url: pr_context.url
           }),
         :ok <-
           RunLedger.record_event(db_path, run_id, %{
             event_type: "github_pr_opened",
             platform: "github",
             external_id: pr_context.external_id,
             payload: %{
               actor: Keyword.get(opts, :actor, "surfer"),
               repo: pr_context.repo,
               title: pr_context.title,
               state: pr_context.state,
               url: pr_context.url
             }
           }),
         :ok <- RunLedger.validate_status_transition(db_path, run_id, "awaiting_review") do
      linear_write_status = maybe_update_linear_pr_external_url(db_path, run_id, pr_context)

      RunLedger.update_status(db_path, run_id, "awaiting_review",
        reason: Keyword.get(opts, :reason, "GitHub PR opened"),
        actor: Keyword.get(opts, :actor, "surfer"),
        github_repo: pr_context.repo,
        github_pr_number: pr_context.external_id,
        external_write_status: external_write_status(linear: linear_write_status)
      )
    end
  end

  defp maybe_update_linear_pr_external_url(db_path, run_id, pr_context) do
    case RunLedger.get_run(db_path, run_id) do
      {:ok, %{"linear_agent_session_id" => session_id}} when is_binary(session_id) ->
        if String.trim(session_id) == "" do
          "skipped"
        else
          update_linear_pr_external_url(db_path, run_id, session_id, pr_context)
        end

      _ ->
        "skipped"
    end
  end

  defp update_linear_pr_external_url(db_path, run_id, session_id, pr_context) do
    urls = github_pr_external_urls(run_id, pr_context.url)

    case call_linear_external_urls(session_id, urls) do
      :ok ->
        "posted"

      {:error, reason} ->
        record_pending_external_url_write(db_path, run_id, session_id, urls, reason)
        "pending"

      other ->
        reason = {:unexpected_external_url_result, other}
        record_pending_external_url_write(db_path, run_id, session_id, urls, reason)
        "pending"
    end
  end

  defp external_write_status(statuses) do
    statuses
    |> Enum.reject(fn {_platform, status} -> status in ["skipped", :skipped, nil] end)
    |> Map.new(fn {platform, status} -> {platform, to_string(status)} end)
  end

  defp github_pr_external_urls(run_id, pr_url) do
    []
    |> maybe_add_surfer_run_url(run_id)
    |> Kernel.++([%{label: "GitHub PR", url: pr_url}])
  end

  defp maybe_add_surfer_run_url(urls, run_id) do
    case Config.settings() do
      {:ok, %{surfer: %{external_base_url: base_url}}} when is_binary(base_url) ->
        [%{label: "Surfer run", url: surfer_run_url(base_url, run_id)} | urls]

      _ ->
        urls
    end
  end

  defp surfer_run_url(external_base_url, run_id) do
    external_base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1/surfer/runs/#{run_id}")
  end

  defp call_linear_external_urls(session_id, urls) do
    case Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun) do
      fun when is_function(fun, 2) -> fun.(session_id, urls)
      _ -> Session.update_external_urls(session_id, urls)
    end
  end

  defp record_pending_external_url_write(db_path, run_id, session_id, urls, reason) do
    external_id = "#{session_id}:external_urls:#{run_id}:github_pr"

    payload = %{
      type: "external_urls",
      session_id: session_id,
      external_urls: urls,
      error: safe_inspect(reason)
    }

    Metrics.emit(:platform_write_failures, %{count: 1}, %{
      run_id: run_id,
      platform: "linear",
      external_id: external_id,
      reason: safe_inspect(reason)
    })

    case RunLedger.record_pending_write(db_path, run_id, %{
           platform: "linear",
           external_id: external_id,
           idempotency_hash: idempotency_hash(payload),
           payload: payload
         }) do
      :ok -> :ok
      {:error, pending_reason} -> Logger.warning("Failed to record pending GitHub PR external URL write run_id=#{run_id}: #{safe_inspect(pending_reason)}")
    end
  end

  defp idempotency_hash(payload) do
    RunLedger.pending_write_idempotency_hash(payload)
  end

  @spec retry(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retry(db_path, previous_run_id, opts \\ []) when is_binary(previous_run_id) do
    with {:ok, previous} <- RunLedger.get_run(db_path, previous_run_id),
         :ok <- require_failed(previous),
         retry_request <- retry_request(previous, opts) do
      claim_retry_run(db_path, previous_run_id, retry_request)
    end
  end

  defp claim_retry_run(db_path, previous_run_id, %RunRequest{} = retry_request) do
    case RunLedger.claim_run(db_path, RunRequest.idempotency_key(retry_request), retry_request, platform: :operator) do
      {:ok, %{status: :claimed, run_id: retry_run_id}} ->
        with :ok <-
               RunLedger.record_link(db_path, retry_run_id, %{
                 platform: "surfer",
                 kind: "retry_of",
                 external_id: previous_run_id
               }) do
          {:ok, %{run_id: retry_run_id, previous_run_id: previous_run_id}}
        end

      {:ok, %{status: :duplicate, run_id: retry_run_id}} ->
        {:ok, %{run_id: retry_run_id, previous_run_id: previous_run_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec requeue_pending_writes(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def requeue_pending_writes(db_path, opts \\ []) when is_binary(db_path) do
    case Keyword.get(opts, :retry_fun) do
      retry_fun when is_function(retry_fun, 1) ->
        actor = Keyword.get(opts, :actor, "operator")

        with {:ok, pending_writes} <- RunLedger.list_pending_writes(db_path) do
          {:ok, Enum.reduce(pending_writes, %{attempted: 0, drained: 0, failed: 0}, &requeue_pending_write(db_path, &1, retry_fun, actor, &2))}
        end

      _ ->
        {:error, :missing_retry_fun}
    end
  end

  defp require_failed(%{"status" => "failed"}), do: :ok
  defp require_failed(%{"status" => status}), do: {:error, {:retry_requires_failed_run, status}}

  defp normalize_github_pr(pr) do
    with {:ok, number} <- normalize_pr_number(value(pr, :number)),
         {:ok, url} <- present(value(pr, :url), :missing_github_pr_url) do
      repo = value(pr, :repo) || repo_from_pr_url(url)

      {:ok,
       %{
         external_id: Integer.to_string(number),
         repo: repo,
         url: url,
         title: value(pr, :title),
         state: value(pr, :state)
       }}
    end
  end

  defp normalize_pr_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp normalize_pr_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_github_pr_number}
    end
  end

  defp normalize_pr_number(nil), do: {:error, :missing_github_pr_number}
  defp normalize_pr_number(_number), do: {:error, :invalid_github_pr_number}

  defp present(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, error), do: {:error, error}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp repo_from_pr_url("https://github.com/" <> rest) do
    case String.split(rest, "/", parts: 4) do
      [owner, repo, "pull", _number] when owner != "" and repo != "" -> "#{owner}/#{repo}"
      _ -> nil
    end
  end

  defp repo_from_pr_url(_url), do: nil

  defp requeue_pending_write(db_path, pending_write, retry_fun, actor, acc) do
    started_at = System.monotonic_time(:millisecond)
    result = safe_retry(retry_fun, pending_write)
    duration_ms = System.monotonic_time(:millisecond) - started_at
    metadata = pending_write_metric_metadata(pending_write)

    Metrics.emit(:platform_write_ms, %{duration_ms: duration_ms}, metadata)

    case result do
      {:ok, response} ->
        :ok = RunLedger.record_pending_write_result(db_path, pending_write, :drained, actor: actor, response: response)
        %{acc | attempted: acc.attempted + 1, drained: acc.drained + 1}

      {:error, reason} ->
        Metrics.emit(:platform_write_failures, %{count: 1}, Map.put(metadata, :reason, safe_inspect(reason)))
        :ok = RunLedger.record_pending_write_result(db_path, pending_write, :failed, actor: actor, reason: reason)
        %{acc | attempted: acc.attempted + 1, failed: acc.failed + 1}
    end
  end

  defp pending_write_metric_metadata(pending_write) when is_map(pending_write) do
    %{
      run_id: Map.get(pending_write, "run_id"),
      platform: Map.get(pending_write, "platform"),
      external_id: Map.get(pending_write, "external_id")
    }
  end

  defp safe_retry(retry_fun, pending_write) do
    case retry_fun.(pending_write) do
      :ok -> {:ok, %{}}
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_retry_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_inspect(reason) do
    reason
    |> SecretRedactor.redact()
    |> inspect()
    |> SecretRedactor.redact_text()
  end

  defp retry_request(previous, opts) do
    previous_run_id = previous["id"]
    nonce = Keyword.get(opts, :nonce) || System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor, "operator")
    previous_context = previous_context(previous)
    source_platform = retry_source_platform(previous_context, previous, opts)

    %RunRequest{
      run_id: "surf_run_retry_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)),
      source: %{
        platform: source_platform,
        trigger_type: :retry,
        raw_event_id: previous_run_id,
        natural_event_key: "operator_retry:#{previous_run_id}:#{nonce}"
      },
      request: %{
        mode: :durable_task,
        trigger_type: :operator,
        title: "Retry #{previous_run_id}",
        body: "Retry of failed Surfer run #{previous_run_id}.",
        prompt_context: nil,
        requested_by: actor
      },
      lineage: %{
        linear: known_context_map(context_value(previous_context, :linear), @linear_lineage_keys),
        discord: known_context_map(context_value(previous_context, :discord), @discord_lineage_keys),
        github: known_context_map(context_value(previous_context, :github), @github_lineage_keys)
      },
      routing: retry_routing(previous_context, previous),
      context: %{
        prompt_context: context_value(previous_context, :prompt_context),
        company_brain_refs: context_value(previous_context, :company_brain_refs) || []
      },
      constraints: RunRequest.constraints_for(:durable_task, source_platform),
      issue: nil,
      organization_id: nil
    }
  end

  defp previous_context(%{"payload_json" => payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, context} when is_map(context) -> context
      _ -> %{}
    end
  end

  defp previous_context(_previous), do: %{}

  defp retry_source_platform(previous_context, previous, opts) do
    opts
    |> Keyword.get(:source_platform)
    |> normalize_source_platform()
    |> case do
      nil ->
        previous_context
        |> context_value(:source_platform)
        |> Kernel.||(Map.get(previous, "source_platform"))
        |> normalize_source_platform()
        |> Kernel.||(:operator)

      platform ->
        platform
    end
  end

  defp normalize_source_platform(platform) when platform in [:linear, :discord, :github, :operator], do: platform
  defp normalize_source_platform("linear"), do: :linear
  defp normalize_source_platform("discord"), do: :discord
  defp normalize_source_platform("github"), do: :github
  defp normalize_source_platform("operator"), do: :operator
  defp normalize_source_platform(_platform), do: nil

  defp retry_routing(previous_context, previous) do
    previous_context
    |> context_value(:routing)
    |> known_context_map(@routing_keys)
    |> maybe_put_previous_repository(previous)
  end

  defp maybe_put_previous_repository(routing, %{"repository" => repository})
       when is_binary(repository) and repository != "" do
    Map.put_new(routing, :repository, repository)
  end

  defp maybe_put_previous_repository(routing, _previous), do: routing

  defp known_context_map(context, keys) when is_map(context) do
    Enum.reduce(keys, %{}, fn key, acc ->
      atom_key = String.to_atom(key)

      case Map.get(context, key) || Map.get(context, atom_key) do
        nil -> acc
        value -> Map.put(acc, atom_key, value)
      end
    end)
  end

  defp known_context_map(_context, _keys), do: %{}

  defp context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, to_string(key))
  end
end
