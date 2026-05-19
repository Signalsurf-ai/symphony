defmodule SymphonyElixir.Surfer.Operator do
  @moduledoc """
  Loopback/operator helpers for Surfer controls, run lookup, and pending-write retry.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Surfer.{Discord, Lifecycle, RunLedger, RunLog, SecretRedactor}
  alias SymphonyElixir.Surfer.Linear.Session

  @runtime_pause_key :surfer_runtime_pause
  @log_tail_lines 50
  @redacted "[REDACTED]"
  @prompt_body_keys MapSet.new(["body", "content", "description", "prompt", "promptcontext", "rawbody", "rawpayload"])
  @raw_platform_payload_keys MapSet.new(["raw", "payload", "platformpayload", "eventpayload", "platformevent", "interactionpayload"])

  @spec lookup_run(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def lookup_run(db_path, run_id) when is_binary(run_id) do
    with {:ok, run} <- RunLedger.get_run(db_path, run_id),
         {:ok, events} <- RunLedger.list_events(db_path, run_id),
         {:ok, links} <- RunLedger.list_links(db_path, run_id) do
      decoded_run = decode_payload(run)

      {:ok,
       %{
         run: decoded_run,
         events: Enum.map(events, &decode_payload/1),
         links: links,
         latest_error: latest_error(decoded_run),
         log_tail: log_tail(run_id)
       }}
    end
  end

  @spec pause(keyword()) :: map()
  def pause(opts \\ []) do
    pause = %{
      paused: true,
      actor: Keyword.get(opts, :actor, "operator"),
      reason: Keyword.get(opts, :reason),
      changed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Application.put_env(:symphony_elixir, @runtime_pause_key, pause)

    mode = pause_mode(opts)
    cancelled_running = maybe_cancel_running(mode, opts, pause.reason)

    opts
    |> Keyword.get(:configured_paused, false)
    |> pause_status()
    |> Map.put(:pause_mode, mode)
    |> Map.put(:cancelled_running, cancelled_running)
  end

  @spec unpause(keyword()) :: map()
  def unpause(opts \\ []) do
    Application.delete_env(:symphony_elixir, @runtime_pause_key)
    pause_status(Keyword.get(opts, :configured_paused, false))
  end

  @spec paused?(boolean()) :: boolean()
  def paused?(configured_paused \\ false) when is_boolean(configured_paused) do
    pause_status(configured_paused).paused
  end

  @spec pause_status(boolean()) :: map()
  def pause_status(configured_paused \\ false) when is_boolean(configured_paused) do
    runtime_pause = runtime_pause()

    %{
      paused: configured_paused or runtime_pause.paused,
      configured_paused: configured_paused,
      runtime_paused: runtime_pause.paused,
      actor: runtime_pause.actor,
      reason: runtime_pause.reason,
      changed_at: runtime_pause.changed_at
    }
  end

  defp pause_mode(opts) do
    opts
    |> Keyword.get(:pause_mode, "drain")
    |> to_string()
    |> String.downcase()
    |> case do
      "cancel" -> "cancel"
      _ -> "drain"
    end
  end

  defp maybe_cancel_running("cancel", opts, reason) do
    server = Keyword.get(opts, :cancel_running_server, Orchestrator)

    case Orchestrator.cancel_running_runs(server, reason: reason || "Surfer paused", actor: Keyword.get(opts, :actor, "operator")) do
      {:ok, summary} -> summary
      :unavailable -> %{count: 0, unavailable: true}
      {:error, error} -> %{count: 0, error: safe_inspect(error)}
    end
  end

  defp maybe_cancel_running(_mode, _opts, _reason), do: %{count: 0}

  @spec requeue_pending_writes(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def requeue_pending_writes(db_path, opts \\ []) when is_binary(db_path) do
    retry_fun = Keyword.get(opts, :retry_fun, &retry_pending_write/1)
    actor = Keyword.get(opts, :actor, "operator")

    Lifecycle.requeue_pending_writes(db_path, retry_fun: retry_fun, actor: actor)
  end

  @spec backup_ledger(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup_ledger(db_path, opts \\ []) when is_binary(db_path) do
    with {:ok, label} <- backup_label(Keyword.get(opts, :label)),
         backup_dir <- Keyword.get(opts, :backup_dir, Path.join(Path.dirname(db_path), "backups")),
         backup_path <- Path.join(backup_dir, "surfer-ledger-#{label}.sqlite3") do
      RunLedger.backup(db_path, backup_path)
    end
  end

  defp backup_label(nil) do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z._-]/, "-")
    |> then(&{:ok, &1})
  end

  defp backup_label(label) when is_binary(label) do
    label = String.trim(label)

    if label =~ ~r/\A[A-Za-z0-9._-]+\z/ do
      {:ok, label}
    else
      {:error, {:invalid_backup_label, label}}
    end
  end

  defp backup_label(label), do: {:error, {:invalid_backup_label, label}}

  defp retry_pending_write(%{"platform" => "linear"} = pending_write) do
    payload = pending_payload(pending_write)

    case {value(payload, :type), value(payload, :session_id)} do
      {"external_urls", session_id} when is_binary(session_id) ->
        retry_linear_external_urls(session_id, value(payload, :external_urls) || [])

      {"started", session_id} when is_binary(session_id) ->
        retry_linear_started(session_id, value(payload, :run_id))

      {"response", session_id} when is_binary(session_id) ->
        retry_linear_activity(session_id, :response, value(payload, :body))

      {"error", session_id} when is_binary(session_id) ->
        retry_linear_activity(session_id, :error, value(payload, :body))

      {type, _session_id} ->
        {:error, {:unsupported_linear_pending_write, type}}
    end
  end

  defp retry_pending_write(%{"platform" => "discord"} = pending_write) do
    payload = pending_payload(pending_write)

    case {value(payload, :type), value(payload, :channel_id), value(payload, :body)} do
      {"channel_message", channel_id, body} when is_binary(channel_id) and is_binary(body) ->
        retry_discord_channel_message(channel_id, body)

      {type, _channel_id, _body} ->
        {:error, {:unsupported_discord_pending_write, type}}
    end
  end

  defp retry_pending_write(%{"platform" => platform}) do
    {:error, {:unsupported_pending_write_platform, platform}}
  end

  defp retry_pending_write(_pending_write), do: {:error, :invalid_pending_write}

  defp retry_linear_external_urls(session_id, external_urls) when is_list(external_urls) do
    case Application.get_env(:symphony_elixir, :surfer_linear_external_urls_fun) do
      fun when is_function(fun, 2) -> fun.(session_id, external_urls)
      _ -> Session.update_external_urls(session_id, external_urls)
    end
  end

  defp retry_linear_external_urls(_session_id, _external_urls), do: {:error, :invalid_linear_external_urls}

  defp retry_linear_started(session_id, run_id) when is_binary(session_id) and is_binary(run_id) do
    case Application.get_env(:symphony_elixir, :surfer_linear_activity_fun) do
      fun when is_function(fun, 2) -> fun.(session_id, run_id)
      _ -> Session.started(session_id, run_id)
    end
  end

  defp retry_linear_started(_session_id, _run_id), do: {:error, :missing_linear_started_run_id}

  defp retry_linear_activity(session_id, type, body) when is_binary(body) do
    case Application.get_env(:symphony_elixir, :surfer_linear_session_activity_fun) do
      fun when is_function(fun, 3) ->
        fun.(session_id, type, body)

      _ ->
        case type do
          :response -> Session.final_response(session_id, body)
          :error -> Session.error(session_id, body)
        end
    end
  end

  defp retry_linear_activity(_session_id, _type, _body), do: {:error, :invalid_linear_activity_body}

  defp retry_discord_channel_message(channel_id, body) do
    case Application.get_env(:symphony_elixir, :surfer_discord_post_fun) do
      fun when is_function(fun, 2) ->
        fun.(channel_id, body)

      _ ->
        bot_token = Config.settings!().surfer.platforms.discord.bot_token
        Discord.Notifier.post_message(channel_id, body, bot_token: bot_token)
    end
  end

  defp safe_inspect(reason) do
    reason
    |> SecretRedactor.redact()
    |> inspect()
    |> SecretRedactor.redact_text()
  end

  defp runtime_pause do
    case Application.get_env(:symphony_elixir, @runtime_pause_key) do
      %{paused: true} = pause ->
        %{
          paused: true,
          actor: Map.get(pause, :actor),
          reason: Map.get(pause, :reason),
          changed_at: Map.get(pause, :changed_at)
        }

      _ ->
        %{paused: false, actor: nil, reason: nil, changed_at: nil}
    end
  end

  defp latest_error(%{"error_code" => nil, "error_message" => nil}), do: nil

  defp latest_error(run) when is_map(run) do
    %{
      "code" => Map.get(run, "error_code"),
      "message" => Map.get(run, "error_message")
    }
  end

  defp log_tail(run_id) do
    case configured_run_log_path(run_id) do
      {:ok, path} -> read_run_log_tail(path)
      :disabled -> global_log_tail(run_id)
    end
  end

  defp global_log_tail(run_id) do
    case Application.get_env(:symphony_elixir, :log_file) do
      path when is_binary(path) -> read_log_tail(path, run_id)
      _ -> []
    end
  end

  defp configured_run_log_path(run_id) do
    case Config.settings() do
      {:ok, %{surfer: %{storage: %{logs_dir: logs_dir}}}} when is_binary(logs_dir) ->
        case String.trim(logs_dir) do
          "" -> :disabled
          configured -> {:ok, RunLog.path(configured, run_id)}
        end

      _ ->
        :disabled
    end
  end

  defp read_run_log_tail(path) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split(~r/\R/, trim: true)
      |> Enum.take(-@log_tail_lines)
      |> Enum.map(&redact_log_line/1)
    else
      _ -> []
    end
  end

  defp read_log_tail(path, run_id) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split(~r/\R/, trim: true)
      |> Enum.filter(&String.contains?(&1, "run_id=#{run_id}"))
      |> Enum.take(-@log_tail_lines)
      |> Enum.map(&redact_log_line/1)
    else
      _ -> []
    end
  end

  defp redact_log_line(line) do
    SecretRedactor.redact_text(line)
  end

  defp decode_payload(row) when is_map(row) do
    case Map.get(row, "payload_json") do
      payload_json when is_binary(payload_json) ->
        payload = decode_json(payload_json)

        redacted_payload =
          payload
          |> SecretRedactor.redact()
          |> redact_lookup_payload()

        row
        |> Map.delete("payload_json")
        |> Map.put("payload", redacted_payload)

      _ ->
        row
        |> SecretRedactor.redact()
        |> redact_lookup_payload()
    end
  end

  defp redact_lookup_payload(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      cond do
        raw_platform_payload_key?(key) -> {key, @redacted}
        prompt_body_key?(key) -> {key, @redacted}
        true -> {key, redact_lookup_payload(nested)}
      end
    end)
  end

  defp redact_lookup_payload(value) when is_list(value), do: Enum.map(value, &redact_lookup_payload/1)
  defp redact_lookup_payload(value), do: value

  defp prompt_body_key?(key) do
    MapSet.member?(@prompt_body_keys, lookup_key(key))
  end

  defp raw_platform_payload_key?(key) do
    MapSet.member?(@raw_platform_payload_keys, lookup_key(key))
  end

  defp lookup_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp decode_json(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, payload} -> payload
      {:error, _reason} -> nil
    end
  end

  defp pending_payload(%{"payload_json" => payload_json}) when is_binary(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp pending_payload(_pending_write), do: %{}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
