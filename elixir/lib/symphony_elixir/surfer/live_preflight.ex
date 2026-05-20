defmodule SymphonyElixir.Surfer.LivePreflight do
  @moduledoc """
  Preflight checks for Surfer v0.1 live smoke validation.
  """

  @platform_env [
    "LINEAR_ACCESS_TOKEN",
    "LINEAR_WEBHOOK_SECRET",
    "LINEAR_TEAM_ID",
    "DISCORD_PUBLIC_KEY",
    "DISCORD_MESSAGE_INGRESS_SECRET",
    "DISCORD_APPLICATION_ID",
    "DISCORD_BOT_TOKEN",
    "DISCORD_GUILD_ID",
    "DISCORD_ALLOWED_GUILDS",
    "DISCORD_ALLOWED_CHANNELS",
    "DISCORD_REPORT_CHANNEL_ID",
    "GITHUB_TOKEN",
    "SURFER_REPOSITORY_URL",
    "SURFER_PUBLIC_URL",
    "SURFER_SQLITE_PATH"
  ]

  @runtime_path_env [
    {"SURFER_WORKSPACE_ROOT", :workspace_root},
    {"SURFER_LOGS_DIR", :logs_dir},
    {"SURFER_STATE_DIR", :state_dir},
    {"SURFER_CODEX_HOME", :codex_home}
  ]

  @comma_list_env MapSet.new([
                    "DISCORD_ALLOWED_GUILDS",
                    "DISCORD_ALLOWED_CHANNELS"
                  ])

  @required_env @platform_env ++ Enum.map(@runtime_path_env, &elem(&1, 0))
  @default_codex_command "codex login status"

  @type result :: %{
          ok?: boolean(),
          missing_env: [String.t()],
          failed_checks: [map()],
          passed_checks: [atom()]
        }

  @spec required_env_vars() :: [String.t()]
  def required_env_vars, do: @required_env

  @spec check(keyword()) :: result()
  def check(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    codex_check? = Keyword.get(opts, :codex_check?, true)
    path_check? = Keyword.get(opts, :path_check?, true)
    command = Keyword.get(opts, :codex_command, @default_codex_command)
    command_runner = Keyword.get(opts, :command_runner, &run_command/1)
    path_checker = Keyword.get(opts, :path_checker, &writable_directory_status/1)
    sqlite_path_checker = Keyword.get(opts, :sqlite_path_checker, &writable_sqlite_path_status/1)
    configured_paused? = Keyword.get(opts, :configured_paused?, false)

    missing_env = missing_env(env)

    {failed_checks, passed_checks} =
      {[], []}
      |> check_public_url(env)
      |> check_surfer_paused(env, configured_paused?)
      |> maybe_check_runtime_paths(path_check?, env, path_checker)
      |> maybe_check_sqlite_path(path_check?, env, sqlite_path_checker)
      |> maybe_check_codex(codex_check?, command, command_runner)

    %{
      ok?: missing_env == [] and failed_checks == [],
      missing_env: missing_env,
      failed_checks: failed_checks,
      passed_checks: passed_checks
    }
  end

  defp missing_env(env) do
    Enum.filter(@required_env, fn key ->
      case Map.get(env, key) do
        value when is_binary(value) -> missing_env_value?(key, value)
        _value -> true
      end
    end)
  end

  defp missing_env_value?(_key, value) when not is_binary(value), do: true

  defp missing_env_value?(key, value) do
    value = String.trim(value)

    cond do
      value == "" ->
        true

      MapSet.member?(@comma_list_env, key) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.all?(&(&1 == ""))

      true ->
        false
    end
  end

  defp check_public_url({failed, passed}, env) do
    case Map.get(env, "SURFER_PUBLIC_URL") do
      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            {failed, passed}

          URI.parse(value).scheme != "https" ->
            {[%{name: :surfer_public_url, reason: :must_be_https_url} | failed], passed}

          not public_url?(value) ->
            {[%{name: :surfer_public_url, reason: :must_be_public_https_url} | failed], passed}

          true ->
            {failed, [:surfer_public_url | passed]}
        end

      _missing ->
        {failed, passed}
    end
  end

  defp public_url?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        public_host?(String.downcase(host))

      _uri ->
        false
    end
  end

  defp public_host?(""), do: false

  defp public_host?(host) do
    host = String.trim_trailing(host, ".")

    if host == "localhost" or String.ends_with?(host, ".localhost") do
      false
    else
      public_address_or_dns_host?(host)
    end
  end

  defp public_address_or_dns_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> public_ip?(address)
      {:error, _reason} -> true
    end
  end

  defp public_ip?({127, _b, _c, _d}), do: false
  defp public_ip?({10, _b, _c, _d}), do: false
  defp public_ip?({100, b, _c, _d}) when b in 64..127, do: false
  defp public_ip?({172, b, _c, _d}) when b in 16..31, do: false
  defp public_ip?({192, 168, _c, _d}), do: false
  defp public_ip?({169, 254, _c, _d}), do: false
  defp public_ip?({0, _b, _c, _d}), do: false
  defp public_ip?({192, 0, 0, _d}), do: false
  defp public_ip?({192, 0, 2, _d}), do: false
  defp public_ip?({198, 18, _c, _d}), do: false
  defp public_ip?({198, 19, _c, _d}), do: false
  defp public_ip?({198, 51, 100, _d}), do: false
  defp public_ip?({203, 0, 113, _d}), do: false

  defp public_ip?({a, _b, _c, _d}) when a >= 224, do: false

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}) do
    public_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})
  end

  defp public_ip?({0x2001, 0x0DB8, _c, _d, _e, _f, _g, _h}), do: false
  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: false
  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: false
  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFF00, do: false

  defp public_ip?(_address), do: true

  defp check_surfer_paused({failed, passed}, env, configured_paused?) do
    env_paused? =
      case Map.get(env, "SURFER_PAUSED") do
        value when is_binary(value) -> truthy_env?(value)
        _missing -> false
      end

    if configured_paused? or env_paused? do
      {[%{name: :surfer_paused, reason: :must_be_unpaused_for_live_smoke} | failed], passed}
    else
      {failed, [:surfer_unpaused | passed]}
    end
  end

  defp truthy_env?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp maybe_check_runtime_paths({failed, passed}, false, _env, _path_checker), do: {failed, passed}

  defp maybe_check_runtime_paths({failed, passed}, true, env, path_checker) do
    Enum.reduce(@runtime_path_env, {failed, passed}, fn {key, name}, {failed_acc, passed_acc} ->
      check_runtime_path(key, name, Map.get(env, key), path_checker, failed_acc, passed_acc)
    end)
  end

  defp check_runtime_path(key, name, path, path_checker, failed, passed) do
    if missing_env_value?(key, path) do
      {failed, passed}
    else
      record_runtime_path_check(key, name, path, path_checker, failed, passed)
    end
  end

  defp record_runtime_path_check(key, name, path, path_checker, failed, passed) do
    case path_checker.(path) do
      :ok -> {failed, [name | passed]}
      {:error, reason} -> {[%{name: :runtime_path, env: key, path: path, reason: reason} | failed], passed}
    end
  end

  defp maybe_check_sqlite_path({failed, passed}, false, _env, _sqlite_path_checker), do: {failed, passed}

  defp maybe_check_sqlite_path({failed, passed}, true, env, sqlite_path_checker) do
    path = Map.get(env, "SURFER_SQLITE_PATH")

    if missing_env_value?("SURFER_SQLITE_PATH", path) do
      {failed, passed}
    else
      case sqlite_path_checker.(path) do
        :ok -> {failed, [:sqlite_path | passed]}
        {:error, reason} -> {[%{name: :sqlite_path, env: "SURFER_SQLITE_PATH", path: path, reason: reason} | failed], passed}
      end
    end
  end

  defp maybe_check_codex({failed, passed}, false, _command, _command_runner), do: {Enum.reverse(failed), Enum.reverse(passed)}

  defp maybe_check_codex({failed, passed}, true, command, command_runner) do
    case command_runner.(command) do
      {:ok, _output} -> {Enum.reverse(failed), Enum.reverse([:codex_oauth | passed])}
      {:error, reason} -> {Enum.reverse([%{name: :codex_oauth, reason: reason} | failed]), Enum.reverse(passed)}
    end
  end

  defp run_command(command) do
    case System.cmd("sh", ["-lc", command], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, :passed}
      {_output, status} -> {:error, {:exit_status, status}}
    end
  end

  defp writable_directory_status(path) when is_binary(path) and path != "" do
    if File.dir?(path) do
      write_probe(path)
    else
      {:error, :missing_directory}
    end
  end

  defp writable_sqlite_path_status(path) when is_binary(path) and path != "" do
    path
    |> Path.dirname()
    |> writable_directory_status()
  end

  defp write_probe(path) do
    probe = Path.join(path, ".surfer-preflight-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, _reason} ->
        {:error, :not_writable}
    end
  end
end
