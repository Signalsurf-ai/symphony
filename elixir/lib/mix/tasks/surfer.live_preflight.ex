defmodule Mix.Tasks.Surfer.LivePreflight do
  use Mix.Task

  alias SymphonyElixir.Surfer.LivePreflight

  @shortdoc "Check Surfer V0.1 live smoke prerequisites"

  @moduledoc """
  Checks required Surfer V0.1 live smoke inputs before running platform smokes.

      mix surfer.live_preflight
      mix surfer.live_preflight --skip-codex
      mix surfer.live_preflight --codex-command "codex login status"
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [help: :boolean, skip_codex: :boolean, codex_command: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        run_preflight(opts)
    end
  end

  defp run_preflight(opts) do
    result =
      LivePreflight.check(
        codex_check?: !Keyword.get(opts, :skip_codex, false),
        codex_command: Keyword.get(opts, :codex_command, "codex login status")
      )

    if result.ok? do
      Mix.shell().info("surfer.live_preflight: live smoke prerequisites present")
      :ok
    else
      print_failures(result)
      Mix.raise("surfer.live_preflight failed")
    end
  end

  defp print_failures(result) do
    if result.missing_env != [] do
      Mix.shell().error("Missing required live smoke environment:")
      Enum.each(result.missing_env, fn key -> Mix.shell().error("- #{key}") end)
    end

    Enum.each(result.failed_checks, &print_failed_check/1)
  end

  defp print_failed_check(%{name: :runtime_path, env: env, path: path, reason: reason}) do
    Mix.shell().error("Failed runtime_path #{env}=#{inspect(path)}: #{inspect(reason)}")
  end

  defp print_failed_check(%{name: :sqlite_path, env: env, path: path, reason: reason}) do
    Mix.shell().error("Failed sqlite_path #{env}=#{inspect(path)}: #{inspect(reason)}")
  end

  defp print_failed_check(%{name: name, reason: reason}) do
    Mix.shell().error("Failed #{name}: #{inspect(reason)}")
  end
end
