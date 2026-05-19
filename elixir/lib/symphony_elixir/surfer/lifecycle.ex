defmodule SymphonyElixir.Surfer.Lifecycle do
  @moduledoc """
  Operator lifecycle controls for locally-ledgered Surfer runs.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Surfer.Linear.Session
  alias SymphonyElixir.Surfer.{Metrics, RunLedger, RunRequest, SecretRedactor}

  @spec cancel(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def cancel(db_path, run_id, opts \\ []) when is_binary(run_id) do
    RunLedger.update_status(db_path, run_id, "cancelled",
      reason: Keyword.get(opts, :reason, "cancelled by operator"),
      actor: Keyword.get(opts, :actor, "operator")
    )
  end

  @spec takeover(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def takeover(db_path, run_id, opts \\ []) when is_binary(run_id) do
    actor = Keyword.get(opts, :actor, "operator")
    reason = Keyword.get(opts, :reason, "taken over by operator")

    with :ok <-
           RunLedger.update_status(db_path, run_id, "awaiting_review",
             reason: reason,
             actor: actor
           ) do
      RunLedger.record_event(db_path, run_id, %{
        event_type: "handoff_note",
        platform: "surfer",
        payload: %{
          actor: actor,
          reason: reason,
          handoff_to: "human",
          note: Keyword.get(opts, :note, "Surfer run #{run_id} was taken over by #{actor}: #{reason}")
        }
      })
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

  defp external_write_status(linear: "skipped"), do: %{}
  defp external_write_status(linear: status), do: %{linear: status}

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
      {:ok,
       %{
         external_id: Integer.to_string(number),
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

    %RunRequest{
      run_id: "surf_run_retry_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)),
      source: %{
        platform: :operator,
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
        linear: %{},
        discord: %{},
        github: %{}
      },
      routing: %{
        repository: previous["repository"]
      },
      context: %{
        prompt_context: nil,
        company_brain_refs: []
      },
      constraints: RunRequest.constraints_for(:durable_task, :operator),
      issue: nil,
      organization_id: nil
    }
  end
end
