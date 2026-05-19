defmodule SymphonyElixir.Surfer.WorkspaceLifecycle do
  @moduledoc """
  Workspace retention and disk-pressure helpers for Surfer.
  """

  alias SymphonyElixir.Surfer.{Metrics, RunLedger}

  @active_statuses MapSet.new(["queued", "running", "awaiting_input", "awaiting_review"])

  @spec cleanup(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cleanup(workspace_root, db_path, opts \\ []) when is_binary(workspace_root) and is_binary(db_path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    successful_ttl_days = Keyword.get(opts, :successful_ttl_days, 14)
    failed_ttl_days = Keyword.get(opts, :failed_ttl_days, 30)

    workspace_root
    |> workspace_paths()
    |> Enum.reduce_while({:ok, %{removed: [], preserved: []}}, fn path, {:ok, acc} ->
      run_id = Path.basename(path)

      case handle_workspace(path, db_path, run_id, now, successful_ttl_days, failed_ttl_days) do
        {:remove, run_id} -> {:cont, {:ok, %{acc | removed: [run_id | acc.removed]}}}
        {:preserve, run_id} -> {:cont, {:ok, %{acc | preserved: [run_id | acc.preserved]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> normalize_cleanup_result()
  end

  @spec disk_pressure?(Path.t(), number(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def disk_pressure?(workspace_root, max_used_percent, opts \\ [])
      when is_binary(workspace_root) and is_number(max_used_percent) do
    disk_usage_fun = Keyword.get(opts, :disk_usage_fun, &disk_usage/1)

    with {:ok, %{used_percent: used_percent} = usage} <- disk_usage_fun.(workspace_root) do
      emit_disk_usage(workspace_root, usage)
      {:ok, used_percent >= max_used_percent}
    end
  end

  defp workspace_paths(workspace_root) do
    workspace_root
    |> Path.join("*/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp handle_workspace(path, db_path, run_id, now, successful_ttl_days, failed_ttl_days) do
    case RunLedger.get_run(db_path, run_id) do
      {:ok, %{"status" => status} = run} when status in ["completed", "failed", "cancelled"] ->
        if expired?(run, now, ttl_days(status, successful_ttl_days, failed_ttl_days)) do
          File.rm_rf!(path)
          {:remove, run_id}
        else
          {:preserve, run_id}
        end

      {:ok, %{"status" => status}} when is_binary(status) ->
        if MapSet.member?(@active_statuses, status), do: {:preserve, run_id}, else: {:preserve, run_id}

      {:error, :not_found} ->
        {:preserve, run_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ttl_days("failed", _successful_ttl_days, failed_ttl_days), do: failed_ttl_days
  defp ttl_days(_status, successful_ttl_days, _failed_ttl_days), do: successful_ttl_days

  defp expired?(run, now, ttl_days) do
    reference_time =
      run["completed_at"] ||
        run["updated_at"] ||
        run["created_at"]

    case DateTime.from_iso8601(reference_time) do
      {:ok, then_at, _offset} -> DateTime.diff(now, then_at, :day) >= ttl_days
      _ -> false
    end
  end

  defp normalize_cleanup_result({:ok, result}) do
    {:ok, %{removed: Enum.reverse(result.removed), preserved: Enum.reverse(result.preserved)}}
  end

  defp normalize_cleanup_result({:error, reason}), do: {:error, reason}

  defp disk_usage(path) do
    File.mkdir_p!(path)

    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df(output)
      {output, status} -> {:error, {:df_failed, status, output}}
    end
  end

  defp emit_disk_usage(workspace_root, %{used_bytes: used_bytes} = usage) when is_integer(used_bytes) do
    Metrics.emit(:workspace_disk_usage_bytes, %{bytes: used_bytes}, %{
      workspace_root: workspace_root,
      used_percent: Map.get(usage, :used_percent)
    })
  end

  defp emit_disk_usage(_workspace_root, _usage), do: :ok

  defp parse_df(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> List.first()
    |> case do
      line when is_binary(line) ->
        fields = String.split(line, ~r/\s+/, trim: true)

        with used_blocks when is_binary(used_blocks) <- Enum.at(fields, 2),
             used_percent when is_binary(used_percent) <- Enum.at(fields, 4),
             {used_blocks, ""} <- Integer.parse(used_blocks),
             {percent, "%"} <- Integer.parse(used_percent) do
          {:ok, %{used_percent: percent, used_bytes: used_blocks * 1024}}
        else
          _ -> {:error, {:unexpected_df_output, output}}
        end

      _ ->
        {:error, {:unexpected_df_output, output}}
    end
  end
end
