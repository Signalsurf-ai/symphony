defmodule SymphonyElixir.Surfer.CodexHealth do
  @moduledoc """
  Startup health checks for Surfer's Codex execution dependency.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Surfer.{Metrics, Operator, SecretRedactor}

  @spec run_startup_check(keyword()) :: :ok | {:error, term()}
  def run_startup_check(opts \\ []) do
    settings_result = Keyword.get(opts, :settings) || Config.settings()

    case settings_result do
      {:ok, settings} ->
        maybe_check_openai_pro_oauth(settings, opts)

      {:error, reason} ->
        Logger.warning("Skipping Codex startup health check because config is unavailable: #{safe_inspect(reason)}")
        :ok
    end
  end

  defp maybe_check_openai_pro_oauth(%{surfer: %{codex: %{auth: "openai_pro_oauth"} = codex} = surfer}, opts) do
    runner = Keyword.get(opts, :runner) || shell_runner(opts, Map.get(codex, :home))
    command = codex.health_check_command || "codex login status"

    case runner.(command) do
      {_output, 0} ->
        Metrics.emit(:codex_health_check, %{ok: 1}, %{auth: :openai_pro_oauth})
        Logger.info("Codex OpenAI Pro OAuth startup health check passed")
        :ok

      {_output, status} when is_integer(status) ->
        reason = "Codex OpenAI Pro OAuth health check failed with exit status #{status}"
        Operator.pause(actor: "surfer:codex_health", reason: reason, configured_paused: surfer.paused)
        Metrics.emit(:codex_health_check, %{ok: 0}, %{auth: :openai_pro_oauth, status: status})
        Logger.error(reason)
        {:error, {:codex_health_check_failed, status}}

      {:error, reason} ->
        pause_reason = "Codex OpenAI Pro OAuth health check failed"
        Operator.pause(actor: "surfer:codex_health", reason: pause_reason, configured_paused: surfer.paused)
        Metrics.emit(:codex_health_check, %{ok: 0}, %{auth: :openai_pro_oauth, status: :error})
        Logger.error("#{pause_reason}: #{safe_inspect(reason)}")
        {:error, {:codex_health_check_failed, reason}}
    end
  end

  defp maybe_check_openai_pro_oauth(_settings, _opts), do: :ok

  defp shell_runner(opts, codex_home) do
    shell_path = Keyword.get(opts, :shell_path, "/bin/sh")
    fn command -> run_shell_command(shell_path, command, codex_home) end
  end

  defp run_shell_command(shell_path, command, codex_home) when is_binary(shell_path) and is_binary(command) do
    System.cmd(shell_path, ["-lc", command], stderr_to_stdout: true, env: codex_env(codex_home))
  rescue
    error -> {:error, error}
  end

  defp safe_inspect(reason) do
    reason
    |> SecretRedactor.redact()
    |> inspect()
    |> SecretRedactor.redact_text()
  end

  defp codex_env(codex_home) when is_binary(codex_home) do
    case String.trim(codex_home) do
      "" -> []
      home -> [{"CODEX_HOME", home}]
    end
  end

  defp codex_env(_codex_home), do: []
end
