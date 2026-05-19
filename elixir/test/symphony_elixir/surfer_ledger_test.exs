defmodule SymphonyElixir.SurferLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.{RunLedger, RunLog, RunRequest}

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "surfer-ledger-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm_rf(db_path) end)

    assert :ok = RunLedger.initialize(db_path)

    %{db_path: db_path}
  end

  test "stores run, event, link, and idempotency records in SQLite", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert :ok = RunLedger.upsert_run(db_path, request, status: "queued")
    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["id"] == request.run_id
    assert run["source_platform"] == "discord"
    assert run["request_mode"] == "code_question"
    assert run["status"] == "queued"

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "received",
               platform: "discord",
               external_id: "message-1",
               payload: %{
                 "body" => "Authorization: Bearer ledger-secret\napi_key=inline-secret\nok=true",
                 "api_key" => "structured-api-key",
                 "password" => "structured-password",
                 "ok" => true
               }
             })

    assert :ok =
             RunLedger.record_link(db_path, request.run_id, %{
               kind: "linear_issue",
               url: "https://linear.app/acme/issue/ENG-1/test",
               external_id: "issue-1"
             })

    assert :ok = RunLedger.record_idempotency_key(db_path, "discord:message-1", request.run_id)
    run_id = request.run_id
    assert {:ok, ^run_id} = RunLedger.lookup_idempotency_key(db_path, "discord:message-1")

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    payload_json = events |> Enum.find(&(&1["event_type"] == "received")) |> Map.fetch!("payload_json")

    assert payload_json =~ "Authorization: Bearer [REDACTED]"
    assert payload_json =~ "api_key=[REDACTED]"
    refute payload_json =~ "ledger-secret"
    refute payload_json =~ "inline-secret"
    refute payload_json =~ "structured-api-key"
    refute payload_json =~ "structured-password"
  end

  test "writes redacted structured JSONL run logs when Surfer logs_dir is configured", %{db_path: db_path} do
    logs_dir = Path.join(System.tmp_dir!(), "surfer-run-logs-#{System.unique_integer([:positive])}")
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

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-structured-log-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "platform_write",
               platform: "discord",
               external_id: "message-structured-log-1",
               payload: %{
                 body: "Authorization: Bearer structured-log-token",
                 platform_payload: %{"request" => "raw webhook payload must not be exposed"},
                 ok: true
               }
             })

    log_path = Path.join(logs_dir, "#{request.run_id}.jsonl")
    assert File.regular?(log_path)

    assert [line] =
             log_path
             |> File.read!()
             |> String.split("\n", trim: true)

    assert {:ok, decoded} = Jason.decode(line)
    assert decoded["run_id"] == request.run_id
    assert decoded["event_type"] == "platform_write"
    assert decoded["platform"] == "discord"
    assert decoded["external_id"] == "message-structured-log-1"
    assert decoded["payload"]["body"] == "[REDACTED]"
    assert decoded["payload"]["platform_payload"] == "[REDACTED]"
    assert decoded["payload"]["ok"] == true
    refute line =~ "structured-log-token"
    refute line =~ "raw webhook payload"
  end

  test "run log appends structured lines and rejects unsafe run ids" do
    logs_dir = Path.join(System.tmp_dir!(), "surfer-run-log-direct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(logs_dir) end)

    run_id = "surf_run_safe-1"
    assert RunLog.path(logs_dir, run_id) == Path.join(logs_dir, "#{run_id}.jsonl")

    assert :ok =
             RunLog.append(logs_dir, run_id, %{
               event_type: "diagnostic",
               payload: %{
                 items: [
                   %{
                     content: "prompt body must not be exposed",
                     event_payload: %{"request" => "raw payload must not be exposed"},
                     ok: true
                   }
                 ]
               }
             })

    assert {:error, :invalid_run_id} = RunLog.append(logs_dir, "../bad", %{event_type: "diagnostic"})

    assert [line] =
             logs_dir
             |> RunLog.path(run_id)
             |> File.read!()
             |> String.split("\n", trim: true)

    assert {:ok, decoded} = Jason.decode(line)
    assert decoded["run_id"] == run_id

    assert decoded["payload"]["items"] == [
             %{
               "content" => "[REDACTED]",
               "event_payload" => "[REDACTED]",
               "ok" => true
             }
           ]

    refute line =~ "prompt body"
    refute line =~ "raw payload"
  end

  test "atomically claims idempotency keys without replacing the first run", %{db_path: db_path} do
    assert {:ok, first_request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    second_request = %{first_request | run_id: "surf_run_second"}
    key = RunRequest.idempotency_key(first_request)

    assert {:ok, %{status: :claimed, run_id: first_run_id}} =
             RunLedger.claim_run(db_path, key, first_request, platform: :discord)

    assert first_run_id == first_request.run_id

    assert {:ok, %{status: :duplicate, run_id: ^first_run_id}} =
             RunLedger.claim_run(db_path, key, second_request, platform: :discord)

    assert {:ok, ^first_run_id} = RunLedger.lookup_idempotency_key(db_path, key)
    assert {:ok, run} = RunLedger.get_run(db_path, first_run_id)
    assert run["status"] == "queued"
    assert {:error, :not_found} = RunLedger.get_run(db_path, "surf_run_second")

    assert {:ok, events} = RunLedger.list_events(db_path, first_run_id)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "duplicate_event" and
               event["platform"] == "discord" and
               event["external_id"] == "message-1" and
               event["payload_json"] =~ key and
               event["payload_json"] =~ "surf_run_second"
           end)
  end

  test "rejects secret-shaped idempotency keys before claiming runs", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-secret-key",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    secret_key = "discord_interaction_token=secret-idempotency-token"

    assert {:error, :secret_idempotency_key} =
             RunLedger.claim_run(db_path, secret_key, request, platform: :discord)

    assert {:error, :secret_idempotency_key} =
             RunLedger.record_idempotency_key(db_path, secret_key, request.run_id)

    assert {:error, :not_found} = RunLedger.get_run(db_path, request.run_id)
    assert {:error, :not_found} = RunLedger.lookup_idempotency_key(db_path, secret_key)
  end

  test "validates run status transitions and records transition events", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    assert :ok =
             RunLedger.update_status(db_path, request.run_id, "awaiting_input",
               reason: "already claimed",
               actor: "surfer"
             )

    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["status"] == "awaiting_input"

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "status_transition" and &1["payload_json"] =~ "awaiting_input"))

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running", reason: "dispatch accepted", actor: "surfer")
    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["status"] == "running"

    assert {:error, {:invalid_transition, "running", "queued"}} =
             RunLedger.update_status(db_path, request.run_id, "queued", reason: "rewind")
  end

  test "redacts secret-shaped status error messages before persisting them", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-redacted-error",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    assert :ok = RunLedger.update_status(db_path, request.run_id, "running")

    error_message =
      "runner failed Authorization: Bearer oauth-secret url=https://discord.com/api/v10/webhooks/app-1/interaction-token-secret/messages/@original"

    assert :ok =
             RunLedger.update_status(db_path, request.run_id, "failed",
               error_code: "runner_failed",
               error_message: error_message
             )

    assert {:ok, run} = RunLedger.get_run(db_path, request.run_id)
    assert run["error_message"] =~ "Authorization: Bearer [REDACTED]"
    assert run["error_message"] =~ "/webhooks/app-1/[REDACTED]/messages/@original"
    refute run["error_message"] =~ "oauth-secret"
    refute run["error_message"] =~ "interaction-token-secret"
  end

  test "redacts secret-shaped link fields before persisting them", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-redacted-link",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert :ok = RunLedger.upsert_run(db_path, request, status: "queued")

    assert :ok =
             RunLedger.record_link(db_path, request.run_id, %{
               platform: "discord",
               kind: "original_response",
               external_id: "discord_interaction_token=external-link-secret",
               url: "https://discord.com/api/v10/webhooks/app-1/interaction-token-secret/messages/@original?access_token=url-link-secret"
             })

    assert {:ok, [link]} = RunLedger.list_links(db_path, request.run_id)
    assert link["external_id"] == "discord_interaction_token=[REDACTED]"
    assert link["url"] =~ "/webhooks/app-1/[REDACTED]/messages/@original"
    assert link["url"] =~ "access_token=[REDACTED]"
    refute link["external_id"] =~ "external-link-secret"
    refute link["url"] =~ "interaction-token-secret"
    refute link["url"] =~ "url-link-secret"
  end

  test "redacts secret-shaped event columns before persisting them", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-redacted-event-columns",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert :ok = RunLedger.upsert_run(db_path, request, status: "queued")

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "pending_write",
               platform: "discord",
               external_id: "discord_interaction_token=event-column-secret",
               idempotency_hash: "access_token=hash-column-secret",
               payload: %{ok: true}
             })

    assert {:ok, [event]} = RunLedger.list_events(db_path, request.run_id)
    assert event["external_id"] == "discord_interaction_token=[REDACTED]"
    assert event["idempotency_hash"] == "access_token=[REDACTED]"
    refute event["external_id"] =~ "event-column-secret"
    refute event["idempotency_hash"] =~ "hash-column-secret"
  end

  test "prunes expired terminal run history with matching idempotency keys only", %{db_path: db_path} do
    old_terminal = discord_request!("message-prune-old-terminal")
    recent_terminal = discord_request!("message-prune-recent-terminal")
    old_active = discord_request!("message-prune-old-active")

    old_terminal_key = RunRequest.idempotency_key(old_terminal)
    recent_terminal_key = RunRequest.idempotency_key(recent_terminal)
    old_active_key = RunRequest.idempotency_key(old_active)

    for {key, request} <- [
          {old_terminal_key, old_terminal},
          {recent_terminal_key, recent_terminal},
          {old_active_key, old_active}
        ] do
      assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, key, request, platform: :discord)
      assert :ok = RunLedger.record_link(db_path, request.run_id, %{platform: "discord", kind: "message", external_id: key})
    end

    cutoff = DateTime.utc_now() |> DateTime.add(-90, :day)
    old = cutoff |> DateTime.add(-1, :day) |> DateTime.to_iso8601()
    recent = cutoff |> DateTime.add(1, :day) |> DateTime.to_iso8601()

    assert :ok = RunLedger.update_status(db_path, old_terminal.run_id, "running", now: old)
    assert :ok = RunLedger.update_status(db_path, old_terminal.run_id, "completed", now: old)
    assert :ok = RunLedger.update_status(db_path, recent_terminal.run_id, "running", now: recent)
    assert :ok = RunLedger.update_status(db_path, recent_terminal.run_id, "completed", now: recent)
    assert :ok = RunLedger.update_status(db_path, old_active.run_id, "running", now: old)

    assert {:ok, %{pruned_runs: [old_run_id], count: 1}} = RunLedger.prune_before(db_path, cutoff)
    assert old_run_id == old_terminal.run_id

    assert {:error, :not_found} = RunLedger.get_run(db_path, old_terminal.run_id)
    assert {:ok, _run} = RunLedger.get_run(db_path, recent_terminal.run_id)
    assert {:ok, _run} = RunLedger.get_run(db_path, old_active.run_id)

    assert {:error, :not_found} = RunLedger.lookup_idempotency_key(db_path, old_terminal_key)
    assert {:ok, _run_id} = RunLedger.lookup_idempotency_key(db_path, recent_terminal_key)
    assert {:ok, _run_id} = RunLedger.lookup_idempotency_key(db_path, old_active_key)

    assert {:ok, []} = RunLedger.list_events(db_path, old_terminal.run_id)
    assert {:ok, []} = RunLedger.list_links(db_path, old_terminal.run_id)
  end

  test "records pending platform writes as outbox events", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-1:response",
               idempotency_hash: "hash-1",
               payload: %{type: "response", body: "Done"}
             })

    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write" and &1["external_id"] == "session-1:response"))

    assert {:ok, [pending]} = RunLedger.list_pending_writes(db_path)
    assert pending["run_id"] == request.run_id
    assert pending["platform"] == "linear"
    assert pending["external_id"] == "session-1:response"

    assert :ok =
             RunLedger.record_pending_write_result(db_path, pending, :drained,
               response: %{ok: true},
               actor: "operator"
             )

    assert {:ok, []} = RunLedger.list_pending_writes(db_path)
    assert {:ok, events} = RunLedger.list_events(db_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "pending_write_drained" and &1["external_id"] == "session-1:response"))
  end

  test "pending write terminal results match the same idempotency hash", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "discord",
               external_id: "channel-1:completion:#{request.run_id}",
               idempotency_hash: "hash-original",
               payload: %{type: "channel_message", body: "First completion"}
             })

    assert {:ok, [original]} = RunLedger.list_pending_writes(db_path)

    assert :ok =
             RunLedger.record_pending_write_result(db_path, original, :failed,
               reason: :discord_down,
               actor: "operator"
             )

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "discord",
               external_id: "channel-1:completion:#{request.run_id}",
               idempotency_hash: "hash-revised",
               payload: %{type: "channel_message", body: "Revised completion"}
             })

    assert {:ok, [pending]} = RunLedger.list_pending_writes(db_path)
    assert pending["external_id"] == "channel-1:completion:#{request.run_id}"
    assert pending["idempotency_hash"] == "hash-revised"
  end

  test "pending write listing emits stale outbox telemetry", %{db_path: db_path} do
    parent = self()
    handler_id = {__MODULE__, self(), :pending_write_backlog_metrics}

    :telemetry.attach_many(
      handler_id,
      [
        [:symphony, :surfer, :pending_write_backlog],
        [:symphony, :surfer, :pending_write_stale]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-stale-pending-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, RunRequest.idempotency_key(request), request, platform: :discord)

    old = DateTime.utc_now() |> DateTime.add(-601, :second) |> DateTime.to_iso8601()

    assert :ok =
             RunLedger.record_pending_write(db_path, request.run_id, %{
               platform: "linear",
               external_id: "session-stale:response",
               idempotency_hash: "hash-stale",
               created_at: old,
               payload: %{type: "response", body: "Done"}
             })

    assert {:ok, [pending]} = RunLedger.list_pending_writes(db_path)
    assert pending["external_id"] == "session-stale:response"

    assert_receive {
      :telemetry,
      [:symphony, :surfer, :pending_write_backlog],
      %{count: 1, oldest_age_ms: oldest_age_ms},
      %{stale_count: 1, stale_after_ms: 600_000}
    }

    assert oldest_age_ms >= 600_000

    assert_receive {
      :telemetry,
      [:symphony, :surfer, :pending_write_stale],
      %{count: 1, oldest_age_ms: stale_age_ms},
      %{stale_after_ms: 600_000}
    }

    assert stale_age_ms >= 600_000
  end

  test "creates a restorable SQLite backup and refuses accidental overwrite", %{db_path: db_path} do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "backup-message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, "backup:message-1", request, platform: :discord)

    assert :ok =
             RunLedger.record_event(db_path, request.run_id, %{
               event_type: "platform_write",
               platform: "discord",
               external_id: "message-1",
               payload: %{body: "ok"}
             })

    backup_path = Path.join(System.tmp_dir!(), "surfer-ledger-backup-#{System.unique_integer([:positive])}.sqlite3")
    restore_path = Path.join(System.tmp_dir!(), "surfer-ledger-restore-#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn ->
      File.rm_rf(backup_path)
      File.rm_rf(restore_path)
    end)

    assert {:ok, backup} = RunLedger.backup(db_path, backup_path)
    assert backup.path == backup_path
    assert backup.size_bytes > 0
    assert backup.integrity == "ok"

    assert {:error, :backup_exists} = RunLedger.backup(db_path, backup_path)
    assert {:ok, %{integrity: "ok", table_count: table_count}} = RunLedger.verify_backup(backup_path)
    assert table_count >= 4

    assert {:ok, restored} = RunLedger.restore_backup(backup_path, restore_path)
    assert restored.path == restore_path
    assert restored.integrity == "ok"

    assert {:ok, run} = RunLedger.get_run(restore_path, request.run_id)
    assert run["id"] == request.run_id
    assert run["status"] == "queued"

    assert {:ok, events} = RunLedger.list_events(restore_path, request.run_id)
    assert Enum.any?(events, &(&1["event_type"] == "platform_write" and &1["external_id"] == "message-1"))

    assert {:error, :restore_target_exists} = RunLedger.restore_backup(backup_path, restore_path)
  end

  test "counts non-terminal Discord runs by channel", %{db_path: db_path} do
    request = fn id, channel_id ->
      assert {:ok, request} =
               RunRequest.from_discord_message(%{
                 "id" => "message-#{id}",
                 "guild_id" => "guild-1",
                 "channel_id" => channel_id,
                 "content" => "surfer question #{id}"
               })

      request
    end

    channel_request = request.(1, "channel-1")
    same_channel_request = request.(2, "channel-1")
    other_channel_request = request.(3, "channel-2")

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, "discord:message-1", channel_request, platform: :discord)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, "discord:message-2", same_channel_request, platform: :discord)

    assert {:ok, %{status: :claimed}} =
             RunLedger.claim_run(db_path, "discord:message-3", other_channel_request, platform: :discord)

    assert {:ok, 2} = RunLedger.count_open_discord_channel_runs(db_path, "channel-1")
    assert :ok = RunLedger.update_status(db_path, channel_request.run_id, "cancelled")
    assert {:ok, 1} = RunLedger.count_open_discord_channel_runs(db_path, "channel-1")
  end

  test "counts daily Discord runs by user and channel", %{db_path: db_path} do
    request = fn id, user_id, channel_id ->
      assert {:ok, request} =
               RunRequest.from_discord_message(%{
                 "id" => "daily-message-#{id}",
                 "guild_id" => "guild-1",
                 "channel_id" => channel_id,
                 "author" => %{"id" => user_id},
                 "content" => "surfer question #{id}"
               })

      request
    end

    first = request.(1, "user-1", "channel-1")
    second = request.(2, "user-1", "channel-1")
    other_user = request.(3, "user-2", "channel-1")
    other_channel = request.(4, "user-1", "channel-2")

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "daily:1", first, platform: :discord)
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "daily:2", second, platform: :discord)
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "daily:3", other_user, platform: :discord)
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "daily:4", other_channel, platform: :discord)

    since = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

    assert {:ok, 3} = RunLedger.count_discord_user_runs_since(db_path, "user-1", since)
    assert {:ok, 3} = RunLedger.count_discord_channel_runs_since(db_path, "channel-1", since)
    assert {:ok, 1} = RunLedger.count_discord_user_runs_since(db_path, "user-2", since)
    assert {:ok, 1} = RunLedger.count_discord_channel_runs_since(db_path, "channel-2", since)
  end

  test "does not count cancelled Discord runs toward daily caps", %{db_path: db_path} do
    request = fn id ->
      assert {:ok, request} =
               RunRequest.from_discord_message(%{
                 "id" => "cancelled-daily-message-#{id}",
                 "guild_id" => "guild-1",
                 "channel_id" => "channel-1",
                 "author" => %{"id" => "user-1"},
                 "content" => "surfer question #{id}"
               })

      request
    end

    accepted = request.(1)
    cancelled = request.(2)

    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "cancelled-daily:1", accepted, platform: :discord)
    assert {:ok, %{status: :claimed}} = RunLedger.claim_run(db_path, "cancelled-daily:2", cancelled, platform: :discord)
    assert :ok = RunLedger.update_status(db_path, cancelled.run_id, "cancelled", reason: "rate limit")

    since = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

    assert {:ok, 1} = RunLedger.count_discord_user_runs_since(db_path, "user-1", since)
    assert {:ok, 1} = RunLedger.count_discord_channel_runs_since(db_path, "channel-1", since)
  end

  defp discord_request!(message_id) do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => message_id,
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question #{message_id}"
             })

    request
  end
end
