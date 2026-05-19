defmodule SymphonyElixir.Surfer.RunLedger do
  @moduledoc """
  Lightweight local SQLite run/event ledger backed by embedded SQLite.
  """

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Config
  alias SymphonyElixir.Surfer.{Metrics, RunLog, RunRequest, SecretRedactor}

  @terminal_statuses MapSet.new(["completed", "failed", "cancelled"])
  @stale_pending_write_after_ms 10 * 60 * 1_000
  @status_transitions %{
    "queued" => MapSet.new(["running", "awaiting_input", "cancelled", "failed"]),
    "running" => MapSet.new(["awaiting_input", "awaiting_review", "completed", "failed", "cancelled"]),
    "awaiting_input" => MapSet.new(["running", "cancelled", "failed"]),
    "awaiting_review" => MapSet.new(["completed", "failed", "cancelled"]),
    "completed" => MapSet.new([]),
    "failed" => MapSet.new([]),
    "cancelled" => MapSet.new([])
  }

  @spec initialize(Path.t()) :: :ok | {:error, term()}
  def initialize(db_path) when is_binary(db_path) do
    File.mkdir_p!(Path.dirname(db_path))

    with_conn(db_path, fn conn ->
      case Sqlite3.execute(conn, "PRAGMA journal_mode = WAL;") do
        :ok -> Sqlite3.execute(conn, schema_sql())
        {:error, reason} -> {:error, {:sqlite, reason}}
      end
    end)
  end

  @spec backup(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup(db_path, backup_path, opts \\ []) when is_binary(db_path) and is_binary(backup_path) do
    with :ok <- reject_same_path(db_path, backup_path),
         :ok <- ensure_target_available(backup_path, Keyword.get(opts, :replace, false), :backup_exists),
         :ok <- mkdir_parent(backup_path),
         :ok <- initialize(db_path),
         :ok <- vacuum_into(db_path, backup_path),
         {:ok, verification} <- verify_backup(backup_path),
         {:ok, stat} <- File.stat(backup_path) do
      {:ok, verification |> Map.put(:path, backup_path) |> Map.put(:size_bytes, stat.size)}
    end
  end

  @spec verify_backup(Path.t()) :: {:ok, map()} | {:error, term()}
  def verify_backup(backup_path) when is_binary(backup_path) do
    with true <- File.regular?(backup_path),
         {:ok, verification} <-
           with_conn(
             backup_path,
             &verify_backup_conn(&1, backup_path),
             mode: :readonly
           ) do
      {:ok, verification}
    else
      false -> {:error, :backup_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_backup_conn(conn, backup_path) do
    with {:ok, integrity} <- integrity_check(conn),
         {:ok, tables} <- ledger_tables(conn) do
      {:ok, %{path: backup_path, integrity: integrity, table_count: length(tables), tables: tables}}
    end
  end

  @spec restore_backup(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_backup(backup_path, restore_path, opts \\ []) when is_binary(backup_path) and is_binary(restore_path) do
    with :ok <- reject_same_path(backup_path, restore_path),
         {:ok, _verification} <- verify_backup(backup_path),
         :ok <- ensure_target_available(restore_path, Keyword.get(opts, :replace, false), :restore_target_exists),
         :ok <- mkdir_parent(restore_path),
         :ok <- copy_file(backup_path, restore_path),
         {:ok, verification} <- verify_backup(restore_path),
         {:ok, stat} <- File.stat(restore_path) do
      {:ok, verification |> Map.put(:path, restore_path) |> Map.put(:size_bytes, stat.size)}
    end
  end

  @spec claim_run(Path.t(), String.t(), RunRequest.t(), keyword()) ::
          {:ok, %{status: :claimed | :duplicate, run_id: String.t()}} | {:error, term()}
  def claim_run(db_path, key, %RunRequest{} = request, opts \\ [])
      when is_binary(db_path) and is_binary(key) do
    result =
      case initialize(db_path) do
        :ok -> with_conn(db_path, &claim_run_with_conn(&1, key, request, opts))
        {:error, reason} -> {:error, reason}
      end

    emit_claim_result(result, request)
    result
  end

  @spec upsert_run(Path.t(), RunRequest.t(), keyword()) :: :ok | {:error, term()}
  def upsert_run(db_path, %RunRequest{} = request, opts \\ []) do
    with_conn(db_path, fn conn ->
      upsert_run_conn(conn, request, opts)
    end)
  end

  @spec get_run(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_run(db_path, run_id) when is_binary(run_id) do
    with_conn(db_path, fn conn ->
      case query_all(
             conn,
             """
             SELECT
               run_id AS id,
               source_platform,
               request_mode,
               repository_key AS repository,
               status,
               linear_issue_id AS canonical_linear_issue_id,
               linear_agent_session_id,
               discord_channel_id,
               discord_message_id,
               github_repo,
               github_pr_number,
               created_at,
               updated_at,
               completed_at,
               error_code,
               error_message,
               payload_json
             FROM runs
             WHERE run_id = ?;
             """,
             [run_id]
           ) do
        {:ok, [row | _]} -> {:ok, row}
        {:ok, []} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec record_event(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_event(db_path, run_id, event) when is_binary(run_id) and is_map(event) do
    result =
      with_conn(db_path, fn conn ->
        record_event_conn(conn, run_id, event)
      end)

    maybe_append_run_log(result, run_id, event)
    result
  end

  @spec list_events(Path.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_events(db_path, run_id) when is_binary(run_id) do
    with_conn(db_path, fn conn ->
      query_all(
        conn,
        """
        SELECT id, run_id, event_type, platform, external_id, idempotency_hash, payload_json, created_at
        FROM run_events
        WHERE run_id = ?
        ORDER BY id ASC;
        """,
        [run_id]
      )
    end)
  end

  @spec list_events_since(Path.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_events_since(db_path, event_type, since_iso8601)
      when is_binary(event_type) and is_binary(since_iso8601) do
    with_conn(db_path, fn conn ->
      query_all(
        conn,
        """
        SELECT id, run_id, event_type, platform, external_id, idempotency_hash, payload_json, created_at
        FROM run_events
        WHERE event_type = ? AND created_at >= ?
        ORDER BY id ASC;
        """,
        [event_type, since_iso8601]
      )
    end)
  end

  @spec count_open_discord_channel_runs(Path.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_open_discord_channel_runs(db_path, channel_id) when is_binary(channel_id) do
    with_conn(db_path, fn conn ->
      case query_all(
             conn,
             """
             SELECT COUNT(*) AS count
             FROM runs
             WHERE source_platform = 'discord'
               AND discord_channel_id = ?
               AND status IN ('queued', 'running', 'awaiting_input', 'awaiting_review');
             """,
             [channel_id]
           ) do
        {:ok, [%{"count" => count} | _]} when is_integer(count) -> {:ok, count}
        {:ok, _rows} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec count_open_linear_session_runs(Path.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_open_linear_session_runs(db_path, session_id, opts \\ [])
      when is_binary(db_path) and is_binary(session_id) do
    exclude_run_id = Keyword.get(opts, :exclude_run_id)

    with_conn(db_path, fn conn ->
      case query_all(
             conn,
             """
             SELECT COUNT(*) AS count
             FROM runs
             WHERE source_platform = 'linear'
               AND linear_agent_session_id = ?
               AND status IN ('queued', 'running', 'awaiting_input', 'awaiting_review')
               AND (? IS NULL OR run_id != ?);
             """,
             [session_id, exclude_run_id, exclude_run_id]
           ) do
        {:ok, [%{"count" => count} | _]} when is_integer(count) -> {:ok, count}
        {:ok, _rows} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec count_discord_user_runs_since(Path.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_discord_user_runs_since(db_path, user_id, since_iso8601)
      when is_binary(user_id) and is_binary(since_iso8601) do
    count_discord_runs_since(db_path, "actor_id", user_id, since_iso8601)
  end

  @spec count_discord_channel_runs_since(Path.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_discord_channel_runs_since(db_path, channel_id, since_iso8601)
      when is_binary(channel_id) and is_binary(since_iso8601) do
    count_discord_runs_since(db_path, "discord_channel_id", channel_id, since_iso8601)
  end

  @spec record_pending_write(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_pending_write(db_path, run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    record_event(db_path, run_id, %{
      event_type: "pending_write",
      platform: value(attrs, :platform),
      external_id: value(attrs, :external_id),
      idempotency_hash: value(attrs, :idempotency_hash),
      created_at: value(attrs, :created_at),
      payload: value(attrs, :payload) || %{}
    })
  end

  @spec list_pending_writes(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pending_writes(db_path) when is_binary(db_path) do
    result =
      with_conn(db_path, fn conn ->
        query_all(
          conn,
          """
          SELECT id, run_id, event_type, platform, external_id, idempotency_hash, payload_json, created_at
          FROM run_events pending
          WHERE pending.event_type = 'pending_write'
            AND pending.external_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1
              FROM run_events terminal
              WHERE terminal.run_id = pending.run_id
                AND terminal.external_id = pending.external_id
                AND terminal.idempotency_hash IS pending.idempotency_hash
                AND terminal.event_type IN ('pending_write_drained', 'pending_write_failed')
            )
          ORDER BY pending.id ASC;
          """,
          []
        )
      end)

    emit_pending_write_backlog(result)
    result
  end

  @spec record_pending_write_result(Path.t(), map(), :drained | :failed, keyword()) :: :ok | {:error, term()}
  def record_pending_write_result(db_path, pending_write, result, opts \\ [])
      when is_map(pending_write) and result in [:drained, :failed] do
    run_id = value(pending_write, :run_id)

    record_event(db_path, run_id, %{
      event_type: "pending_write_#{result}",
      platform: value(pending_write, :platform),
      external_id: value(pending_write, :external_id),
      idempotency_hash: value(pending_write, :idempotency_hash),
      payload: %{
        actor: Keyword.get(opts, :actor),
        reason: format_optional(Keyword.get(opts, :reason)),
        response: Keyword.get(opts, :response)
      }
    })
  end

  @spec record_link(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_link(db_path, run_id, link) when is_binary(run_id) and is_map(link) do
    with_conn(db_path, fn conn ->
      execute(
        conn,
        """
        INSERT INTO run_links(run_id, platform, kind, external_id, url, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        [
          run_id,
          value(link, :platform),
          value(link, :kind),
          value(link, :external_id),
          value(link, :url),
          timestamp()
        ]
      )
    end)
  end

  @spec list_links(Path.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_links(db_path, run_id) when is_binary(run_id) do
    with_conn(db_path, fn conn ->
      query_all(
        conn,
        """
        SELECT id, run_id, platform, kind, external_id, url, created_at
        FROM run_links
        WHERE run_id = ?
        ORDER BY id ASC;
        """,
        [run_id]
      )
    end)
  end

  @spec record_idempotency_key(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_idempotency_key(db_path, key, run_id)
      when is_binary(key) and is_binary(run_id) do
    with_conn(db_path, fn conn ->
      execute(
        conn,
        "INSERT INTO idempotency_keys(key, run_id, created_at) VALUES (?, ?, ?) ON CONFLICT(key) DO NOTHING;",
        [key, run_id, timestamp()]
      )
    end)
  end

  @spec lookup_idempotency_key(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def lookup_idempotency_key(db_path, key) when is_binary(key) do
    with_conn(db_path, fn conn ->
      lookup_idempotency_key_conn(conn, key)
    end)
  end

  @spec update_status(Path.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_status(db_path, run_id, next_status, opts \\ [])
      when is_binary(run_id) and is_binary(next_status) do
    result = with_conn(db_path, &update_status_with_conn(&1, run_id, next_status, opts))
    emit_status_result(result, run_id, next_status)
    result
  end

  defp emit_claim_result({:ok, %{status: :claimed, run_id: run_id}}, request) do
    Metrics.emit(:runs_started, %{count: 1}, %{
      run_id: run_id,
      source_platform: request.source.platform,
      request_mode: request.request.mode
    })
  end

  defp emit_claim_result({:ok, %{status: :duplicate, run_id: run_id}}, request) do
    Metrics.emit(:duplicate_events, %{count: 1}, %{
      run_id: run_id,
      source_platform: request.source.platform,
      request_mode: request.request.mode
    })
  end

  defp emit_claim_result(_result, _request), do: :ok

  defp emit_status_result(:ok, run_id, "completed"), do: Metrics.emit(:runs_completed, %{count: 1}, %{run_id: run_id})
  defp emit_status_result(:ok, run_id, "failed"), do: Metrics.emit(:runs_failed, %{count: 1}, %{run_id: run_id})
  defp emit_status_result(:ok, run_id, "cancelled"), do: Metrics.emit(:runs_cancelled, %{count: 1}, %{run_id: run_id})
  defp emit_status_result(_result, _run_id, _status), do: :ok

  defp emit_pending_write_backlog({:ok, rows}) when is_list(rows) do
    now = DateTime.utc_now()
    ages = Enum.flat_map(rows, &pending_write_age_ms(&1, now))
    oldest_age_ms = Enum.max([0 | ages])
    stale_count = Enum.count(ages, &(&1 >= @stale_pending_write_after_ms))

    Metrics.emit(:pending_write_backlog, %{count: length(rows), oldest_age_ms: oldest_age_ms}, %{
      stale_count: stale_count,
      stale_after_ms: @stale_pending_write_after_ms
    })

    if stale_count > 0 do
      Metrics.emit(:pending_write_stale, %{count: stale_count, oldest_age_ms: oldest_age_ms}, %{
        stale_after_ms: @stale_pending_write_after_ms
      })
    end
  end

  defp emit_pending_write_backlog(_result), do: :ok

  defp pending_write_age_ms(%{"created_at" => created_at}, now) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, created_at, _offset} -> [max(0, DateTime.diff(now, created_at, :millisecond))]
      _ -> []
    end
  end

  defp pending_write_age_ms(_pending_write, _now), do: []

  defp maybe_append_run_log(:ok, run_id, event) do
    case configured_logs_dir() do
      {:ok, logs_dir} -> RunLog.append(logs_dir, run_id, event)
      :disabled -> :ok
    end
  end

  defp maybe_append_run_log(_result, _run_id, _event), do: :ok

  defp configured_logs_dir do
    case Config.settings() do
      {:ok, %{surfer: %{storage: %{logs_dir: logs_dir}}}} when is_binary(logs_dir) ->
        case String.trim(logs_dir) do
          "" -> :disabled
          configured -> {:ok, configured}
        end

      _ ->
        :disabled
    end
  end

  defp claim_run_with_conn(conn, key, request, opts) do
    transaction(conn, fn -> claim_run_in_transaction(conn, key, request, opts) end)
  end

  defp update_status_with_conn(conn, run_id, next_status, opts) do
    transaction(conn, fn -> update_status_in_transaction(conn, run_id, next_status, opts) end)
  end

  defp update_status_in_transaction(conn, run_id, next_status, opts) do
    with {:ok, current_status} <- current_status(conn, run_id),
         :ok <- validate_transition(current_status, next_status),
         :ok <- update_status_conn(conn, run_id, next_status, opts) do
      record_event_conn(conn, run_id, status_transition_event(current_status, next_status, opts))
    end
  end

  defp claim_run_in_transaction(conn, key, request, opts) do
    now = timestamp()

    with :ok <- insert_idempotency_claim(conn, key, request.run_id, now),
         {:ok, changes} <- Sqlite3.changes(conn) do
      finish_claim(conn, key, request, opts, now, changes)
    end
  end

  defp insert_idempotency_claim(conn, key, run_id, now) do
    execute(
      conn,
      "INSERT INTO idempotency_keys(key, run_id, created_at) VALUES (?, ?, ?) ON CONFLICT(key) DO NOTHING;",
      [key, run_id, now]
    )
  end

  defp finish_claim(conn, _key, request, opts, now, 1) do
    with :ok <- upsert_run_conn(conn, request, status: "queued", now: now) do
      record_event_conn(conn, request.run_id, %{
        event_type: "ingress_received",
        platform: Keyword.get(opts, :platform),
        external_id: request.source.raw_event_id,
        payload: RunRequest.surfer_context(request)
      })
    end
    |> case do
      :ok -> {:ok, %{status: :claimed, run_id: request.run_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_claim(conn, key, request, opts, _now, _changes) do
    case lookup_idempotency_key_conn(conn, key) do
      {:ok, run_id} ->
        record_duplicate_event(conn, run_id, key, request, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_duplicate_event(conn, run_id, key, request, opts) do
    result =
      record_event_conn(conn, run_id, %{
        event_type: "duplicate_event",
        platform: Keyword.get(opts, :platform),
        external_id: request.source.raw_event_id,
        payload: %{
          idempotency_key: key,
          existing_run_id: run_id,
          duplicate_run_id: request.run_id,
          source_platform: request.source.platform,
          request_mode: request.request.mode
        }
      })

    case result do
      :ok -> {:ok, %{status: :duplicate, run_id: run_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_discord_runs_since(db_path, column, value, since_iso8601)
       when column in ["actor_id", "discord_channel_id"] do
    with_conn(db_path, fn conn ->
      case query_all(
             conn,
             """
             SELECT COUNT(*) AS count
             FROM runs
             WHERE source_platform = 'discord'
               AND #{column} = ?
               AND status != 'cancelled'
               AND created_at >= ?;
             """,
             [value, since_iso8601]
           ) do
        {:ok, [%{"count" => count} | _]} when is_integer(count) -> {:ok, count}
        {:ok, _rows} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp reject_same_path(first_path, second_path) do
    if Path.expand(first_path) == Path.expand(second_path) do
      {:error, :same_path}
    else
      :ok
    end
  end

  defp ensure_target_available(path, true, _exists_error) do
    if File.exists?(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:file, reason}}
      end
    else
      :ok
    end
  end

  defp ensure_target_available(path, _replace, exists_error) do
    if File.exists?(path), do: {:error, exists_error}, else: :ok
  end

  defp mkdir_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp copy_file(source_path, target_path) do
    case File.cp(source_path, target_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp vacuum_into(db_path, backup_path) do
    with_conn(db_path, fn conn ->
      execute(conn, "VACUUM main INTO ?;", [backup_path])
    end)
  end

  defp integrity_check(conn) do
    case query_all(conn, "PRAGMA integrity_check;", []) do
      {:ok, [%{"integrity_check" => "ok"} | _]} -> {:ok, "ok"}
      {:ok, [%{"integrity_check" => reason} | _]} -> {:error, {:integrity_check_failed, reason}}
      {:ok, rows} -> {:error, {:unexpected_integrity_check, rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ledger_tables(conn) do
    expected_tables = ["runs", "run_events", "run_links", "idempotency_keys"]

    case query_all(
           conn,
           """
           SELECT name
           FROM sqlite_master
           WHERE type = 'table'
             AND name IN ('runs', 'run_events', 'run_links', 'idempotency_keys')
           ORDER BY name ASC;
           """,
           []
         ) do
      {:ok, rows} ->
        tables = Enum.map(rows, & &1["name"])

        if Enum.all?(expected_tables, &(&1 in tables)) do
          {:ok, tables}
        else
          {:error, {:missing_ledger_tables, expected_tables -- tables}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_transition_event(current_status, next_status, opts) do
    payload =
      %{
        from: current_status,
        to: next_status,
        reason: Keyword.get(opts, :reason),
        actor: Keyword.get(opts, :actor)
      }
      |> maybe_put_external_write_status(Keyword.get(opts, :external_write_status))

    %{
      event_type: "status_transition",
      platform: Keyword.get(opts, :platform),
      external_id: Keyword.get(opts, :external_id),
      payload: payload
    }
  end

  defp maybe_put_external_write_status(payload, status) when is_map(status) and map_size(status) > 0 do
    Map.put(payload, :external_write_status, normalize_external_write_status(status))
  end

  defp maybe_put_external_write_status(payload, _status), do: payload

  defp normalize_external_write_status(status) do
    Map.new(status, fn {platform, outcome} -> {to_string(platform), format_optional(outcome)} end)
  end

  defp upsert_run_conn(conn, %RunRequest{} = request, opts) do
    now = Keyword.get(opts, :now, timestamp())
    status = Keyword.get(opts, :status, "queued")
    context = RunRequest.surfer_context(request)

    execute(
      conn,
      """
      INSERT INTO runs(
        run_id,
        status,
        source_platform,
        request_mode,
        repository_key,
        created_by,
        actor_id,
        correlation_id,
        linear_issue_id,
        linear_agent_session_id,
        discord_channel_id,
        discord_message_id,
        github_repo,
        github_pr_number,
        created_at,
        updated_at,
        payload_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(run_id) DO UPDATE SET
        status = excluded.status,
        repository_key = excluded.repository_key,
        linear_issue_id = excluded.linear_issue_id,
        linear_agent_session_id = excluded.linear_agent_session_id,
        discord_channel_id = excluded.discord_channel_id,
        discord_message_id = excluded.discord_message_id,
        github_repo = excluded.github_repo,
        github_pr_number = excluded.github_pr_number,
        updated_at = excluded.updated_at,
        payload_json = excluded.payload_json;
      """,
      [
        request.run_id,
        status,
        to_string(request.source.platform),
        to_string(request.request.mode),
        route_value(request, :repository),
        request.request[:requested_by],
        request.request[:requested_by],
        request.source[:natural_event_key] || request.source[:raw_event_id],
        request.lineage.linear[:issue_id],
        request.lineage.linear[:agent_session_id],
        request.lineage.discord[:channel_id],
        request.lineage.discord[:message_id],
        request.lineage.github[:repo],
        request.lineage.github[:pull_request_number],
        now,
        now,
        encode_payload(context)
      ]
    )
  end

  defp current_status(conn, run_id) do
    case query_all(conn, "SELECT status FROM runs WHERE run_id = ?;", [run_id]) do
      {:ok, [%{"status" => status}]} when is_binary(status) -> {:ok, status}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_status_conn(conn, run_id, next_status, opts) do
    now = Keyword.get(opts, :now, timestamp())

    completed_at =
      if MapSet.member?(@terminal_statuses, next_status) do
        now
      end

    execute(
      conn,
      """
      UPDATE runs
      SET status = ?, updated_at = ?, completed_at = COALESCE(?, completed_at), error_code = ?, error_message = ?
      WHERE run_id = ?;
      """,
      [
        next_status,
        now,
        completed_at,
        Keyword.get(opts, :error_code) |> redacted_optional(),
        Keyword.get(opts, :error_message) |> redacted_optional(),
        run_id
      ]
    )
  end

  defp validate_transition(status, status), do: :ok

  defp validate_transition(current_status, next_status) do
    allowed_next = Map.get(@status_transitions, current_status, MapSet.new())

    if MapSet.member?(allowed_next, next_status) do
      :ok
    else
      {:error, {:invalid_transition, current_status, next_status}}
    end
  end

  defp lookup_idempotency_key_conn(conn, key) do
    case query_all(conn, "SELECT run_id FROM idempotency_keys WHERE key = ?;", [key]) do
      {:ok, [%{"run_id" => run_id} | _]} -> {:ok, run_id}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_event_conn(conn, run_id, event) do
    created_at = value(event, :created_at) || timestamp()

    execute(
      conn,
      """
      INSERT INTO run_events(run_id, event_type, platform, external_id, idempotency_hash, payload_json, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?);
      """,
      [
        run_id,
        value(event, :event_type),
        value(event, :platform) |> maybe_to_string(),
        value(event, :external_id),
        value(event, :idempotency_hash),
        encode_payload(value(event, :payload) || %{}),
        created_at
      ]
    )
  end

  defp with_conn(db_path, fun, opts \\ []) when is_binary(db_path) and is_function(fun, 1) do
    mode = Keyword.get(opts, :mode, :readwrite)

    case Sqlite3.open(db_path, mode: mode) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          _ = Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, {:sqlite, reason}}
    end
  end

  defp transaction(conn, fun) when is_function(fun, 0) do
    case Sqlite3.execute(conn, "BEGIN IMMEDIATE;") do
      :ok -> finish_transaction(conn, fun.())
      {:error, reason} -> {:error, {:sqlite, reason}}
    end
  end

  defp finish_transaction(conn, {:error, _reason} = error) do
    _ = Sqlite3.execute(conn, "ROLLBACK;")
    error
  end

  defp finish_transaction(conn, result) do
    case Sqlite3.execute(conn, "COMMIT;") do
      :ok -> result
      {:error, reason} -> {:error, {:sqlite, reason}}
    end
  end

  defp execute(conn, sql, params) when is_binary(sql) and is_list(params) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          :ok = Sqlite3.bind(stmt, params)

          case Sqlite3.step(conn, stmt) do
            :done -> :ok
            {:row, _row} -> :ok
            :busy -> {:error, :sqlite_busy}
            {:error, reason} -> {:error, {:sqlite, reason}}
          end
        after
          _ = Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, {:sqlite, reason}}
    end
  end

  defp query_all(conn, sql, params) when is_binary(sql) and is_list(params) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          :ok = Sqlite3.bind(stmt, params)
          fetch_query_rows(conn, stmt)
        after
          _ = Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, {:sqlite, reason}}
    end
  end

  defp fetch_query_rows(conn, stmt) do
    with {:ok, columns} <- Sqlite3.columns(conn, stmt),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
      {:ok, Enum.map(rows, &row_to_map(columns, &1))}
    else
      {:error, reason} -> {:error, {:sqlite, reason}}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end

  defp schema_sql do
    """
    CREATE TABLE IF NOT EXISTS runs(
      run_id TEXT PRIMARY KEY,
      status TEXT NOT NULL,
      source_platform TEXT,
      request_mode TEXT,
      repository_key TEXT,
      created_by TEXT,
      actor_id TEXT,
      correlation_id TEXT,
      linear_issue_id TEXT,
      linear_agent_session_id TEXT,
      discord_channel_id TEXT,
      discord_message_id TEXT,
      github_repo TEXT,
      github_pr_number TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      error_code TEXT,
      error_message TEXT,
      payload_json TEXT
    );

    CREATE TABLE IF NOT EXISTS run_events(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      platform TEXT,
      external_id TEXT,
      idempotency_hash TEXT,
      payload_json TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS run_links(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id TEXT NOT NULL,
      platform TEXT,
      kind TEXT,
      external_id TEXT,
      url TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS idempotency_keys(
      key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS runs_status_updated_at_idx ON runs(status, updated_at);
    CREATE INDEX IF NOT EXISTS runs_discord_actor_created_at_idx ON runs(source_platform, actor_id, created_at);
    CREATE INDEX IF NOT EXISTS runs_discord_channel_created_at_idx ON runs(source_platform, discord_channel_id, created_at);
    CREATE INDEX IF NOT EXISTS run_events_run_id_idx ON run_events(run_id);
    CREATE INDEX IF NOT EXISTS run_events_external_id_idx ON run_events(external_id);
    CREATE INDEX IF NOT EXISTS run_links_run_id_idx ON run_links(run_id);
    """
  end

  defp route_value(%RunRequest{} = request, key) do
    Map.get(request.routing, key) || Map.get(request.routing, to_string(key))
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp format_optional(nil), do: nil
  defp format_optional(value) when is_binary(value), do: value
  defp format_optional(value), do: inspect(value)

  defp redacted_optional(nil), do: nil

  defp redacted_optional(value) do
    value
    |> format_optional()
    |> SecretRedactor.redact_text()
  end

  defp encode_payload(payload) do
    payload
    |> SecretRedactor.redact()
    |> Jason.encode!()
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
