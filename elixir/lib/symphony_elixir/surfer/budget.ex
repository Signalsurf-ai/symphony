defmodule SymphonyElixir.Surfer.Budget do
  @moduledoc """
  Budget ledger helpers for Surfer Codex usage controls.
  """

  alias SymphonyElixir.Surfer.{Metrics, RunLedger}

  @spec record_usage(Path.t(), String.t(), number()) :: :ok | {:error, term()}
  def record_usage(db_path, run_id, amount_usd) when is_binary(run_id) and is_number(amount_usd) and amount_usd >= 0 do
    case RunLedger.record_event(db_path, run_id, %{
           event_type: "budget_usage",
           platform: "codex",
           payload: %{amount_usd: amount_usd}
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec check_daily_cap(Path.t(), number() | nil) :: :ok | {:error, term()}
  def check_daily_cap(_db_path, nil), do: :ok

  def check_daily_cap(db_path, limit_usd) when is_number(limit_usd) and limit_usd > 0 do
    case daily_usage_usd(db_path, Date.utc_today()) do
      {:ok, used_usd} ->
        metadata = %{limit_usd: limit_usd, used_usd: used_usd}

        Metrics.emit(:daily_codex_budget_remaining, %{amount_usd: max(limit_usd - used_usd, 0.0)}, metadata)

        if used_usd >= limit_usd do
          Metrics.emit(:budget_cap_hits, %{count: 1}, metadata)
          {:error, {:daily_budget_cap_exceeded, metadata}}
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def check_daily_cap(_db_path, _limit_usd), do: :ok

  @spec check_run_cap(Path.t(), String.t(), number() | nil) :: :ok | {:error, term()}
  def check_run_cap(_db_path, _run_id, nil), do: :ok

  def check_run_cap(db_path, run_id, limit_usd) when is_binary(run_id) and is_number(limit_usd) and limit_usd > 0 do
    case run_usage_usd(db_path, run_id) do
      {:ok, used_usd} ->
        metadata = %{limit_usd: limit_usd, run_id: run_id, used_usd: used_usd}

        if used_usd >= limit_usd do
          Metrics.emit(:budget_cap_hits, %{count: 1}, metadata)
          mark_run_budget_cap_failed(db_path, run_id)
          {:error, {:run_budget_cap_exceeded, metadata}}
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def check_run_cap(_db_path, _run_id, _limit_usd), do: :ok

  @spec run_usage_usd(Path.t(), String.t()) :: {:ok, float()} | {:error, term()}
  def run_usage_usd(db_path, run_id) when is_binary(run_id) do
    with {:ok, events} <- RunLedger.list_events(db_path, run_id) do
      {:ok,
       events
       |> Enum.filter(&(Map.get(&1, "event_type") == "budget_usage"))
       |> Enum.reduce(0.0, &(&2 + budget_amount(&1)))}
    end
  end

  @spec daily_usage_usd(Path.t(), Date.t()) :: {:ok, float()} | {:error, term()}
  def daily_usage_usd(db_path, %Date{} = date) do
    since =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.to_iso8601()

    with {:ok, events} <- RunLedger.list_events_since(db_path, "budget_usage", since) do
      {:ok, Enum.reduce(events, 0.0, &(&2 + budget_amount(&1)))}
    end
  end

  defp budget_amount(%{"payload_json" => payload_json}) when is_binary(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, %{"amount_usd" => amount}} when is_number(amount) -> amount * 1.0
      _ -> 0.0
    end
  end

  defp budget_amount(_event), do: 0.0

  defp mark_run_budget_cap_failed(db_path, run_id) do
    RunLedger.update_status(db_path, run_id, "failed",
      reason: "per-run budget cap exceeded",
      actor: "surfer",
      error_code: "budget_cap",
      error_message: "Per-run Codex budget cap exceeded"
    )
  end
end
