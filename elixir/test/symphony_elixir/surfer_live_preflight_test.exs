defmodule SymphonyElixir.SurferLivePreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.LivePreflight

  test "reports missing live smoke environment without running Codex" do
    result = LivePreflight.check(env: %{}, codex_check?: false, path_check?: false)

    refute result.ok?
    assert "LINEAR_API_KEY" in result.missing_env
    assert "LINEAR_WEBHOOK_SECRET" in result.missing_env
    assert "DISCORD_MESSAGE_INGRESS_SECRET" in result.missing_env
    assert "DISCORD_APPLICATION_ID" in result.missing_env
    assert "GITHUB_TOKEN" in result.missing_env
    assert "SURFER_PUBLIC_URL" in result.missing_env
    assert "SURFER_WORKSPACE_ROOT" in result.missing_env
    assert "SURFER_LOGS_DIR" in result.missing_env
    assert "SURFER_STATE_DIR" in result.missing_env
    assert "SURFER_SQLITE_PATH" in result.missing_env
    assert "SURFER_CODEX_HOME" in result.missing_env
    assert result.failed_checks == []
  end

  test "passes required environment and records Codex OAuth health" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    result =
      LivePreflight.check(
        env: env,
        codex_command: "codex login status",
        command_runner: fn "codex login status" -> {:ok, "Logged in"} end
      )

    assert result.ok?
    assert result.missing_env == []
    assert :codex_oauth in result.passed_checks
  end

  test "requires PRD-style Discord allowlist environment variables" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    env =
      env
      |> Map.delete("DISCORD_ALLOWED_GUILDS")
      |> Map.delete("DISCORD_ALLOWED_CHANNELS")

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?
    assert "DISCORD_ALLOWED_GUILDS" in result.missing_env
    assert "DISCORD_ALLOWED_CHANNELS" in result.missing_env
  end

  test "rejects empty Discord allowlist values before live smoke" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    env =
      env
      |> Map.put("DISCORD_ALLOWED_GUILDS", " , ")
      |> Map.put("DISCORD_ALLOWED_CHANNELS", ",,")

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?
    assert "DISCORD_ALLOWED_GUILDS" in result.missing_env
    assert "DISCORD_ALLOWED_CHANNELS" in result.missing_env
  end

  test "default check reads process environment and Codex login status" do
    original_env = Map.new(LivePreflight.required_env_vars(), &{&1, System.get_env(&1)})
    original_path = System.get_env("PATH")
    bin_dir = Path.join(System.tmp_dir!(), "surfer-live-preflight-bin-#{System.unique_integer([:positive])}")
    codex_path = Path.join(bin_dir, "codex")
    {env, cleanup_paths} = required_env_with_paths()

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore_env("PATH", original_path)
      File.rm_rf(bin_dir)
      cleanup_paths.()
    end)

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    test "$1 $2" = "login status"
    """)

    File.chmod!(codex_path, 0o755)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    assert %{ok?: true} = LivePreflight.check()
  end

  test "fails when Codex OAuth health command fails" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    result =
      LivePreflight.check(
        env: env,
        codex_command: "codex login status",
        command_runner: fn "codex login status" -> {:error, {:exit_status, 1}} end
      )

    refute result.ok?
    assert %{name: :codex_oauth, reason: {:exit_status, 1}} in result.failed_checks
  end

  test "runs the default shell-backed Codex health command" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    assert %{ok?: true, failed_checks: [], passed_checks: passed_checks} =
             LivePreflight.check(env: env, codex_command: "printf ok")

    assert :codex_oauth in passed_checks

    assert %{ok?: false, failed_checks: failed_checks} =
             LivePreflight.check(env: env, codex_command: "exit 7")

    assert %{name: :codex_oauth, reason: {:exit_status, 7}} in failed_checks
  end

  test "requires a public HTTPS Surfer URL for Linear external run links" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    env = Map.put(env, "SURFER_PUBLIC_URL", "http://localhost:4000")

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?
    assert %{name: :surfer_public_url, reason: :must_be_https_url} in result.failed_checks
  end

  test "treats blank Surfer public URLs as missing environment" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    env = Map.put(env, "SURFER_PUBLIC_URL", "   ")

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?
    assert "SURFER_PUBLIC_URL" in result.missing_env
    refute Enum.any?(result.failed_checks, &match?(%{name: :surfer_public_url}, &1))
  end

  test "rejects local or hostless Surfer public URLs before live smoke" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    urls = [
      "https://",
      "https:surfer",
      "https://localhost:4000",
      "https://localhost.",
      "https://agent.localhost",
      "https://127.0.0.1:4000",
      "https://10.0.0.1",
      "https://100.64.0.1",
      "https://172.16.0.1",
      "https://192.168.0.1",
      "https://169.254.0.1",
      "https://0.0.0.0",
      "https://192.0.0.1",
      "https://192.0.2.1",
      "https://198.18.0.1",
      "https://198.19.0.1",
      "https://198.51.100.1",
      "https://203.0.113.1",
      "https://224.0.0.1",
      "https://[::1]",
      "https://[::]",
      "https://[::ffff:127.0.0.1]",
      "https://[2001:db8::1]",
      "https://[fc00::1]",
      "https://[fe80::1]",
      "https://[ff00::1]"
    ]

    Enum.each(urls, fn url ->
      result =
        env
        |> Map.put("SURFER_PUBLIC_URL", url)
        |> then(&LivePreflight.check(env: &1, codex_check?: false))

      refute result.ok?, "expected #{url} to fail live preflight"

      assert %{name: :surfer_public_url, reason: :must_be_public_https_url} in result.failed_checks
    end)
  end

  test "accepts public HTTPS host and IP URLs before live smoke" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    urls = [
      "https://surfer.example.com",
      "https://surfer.example.com.",
      "https://8.8.8.8",
      "https://[2606:4700:4700::1111]"
    ]

    Enum.each(urls, fn url ->
      result =
        env
        |> Map.put("SURFER_PUBLIC_URL", url)
        |> then(&LivePreflight.check(env: &1, codex_check?: false))

      assert result.ok?, "expected #{url} to pass live preflight"
      assert :surfer_public_url in result.passed_checks
    end)
  end

  test "requires writable runtime mount paths" do
    env =
      required_env()
      |> Map.merge(%{
        "SURFER_WORKSPACE_ROOT" => Path.join(System.tmp_dir!(), "missing-workspaces"),
        "SURFER_LOGS_DIR" => Path.join(System.tmp_dir!(), "missing-logs"),
        "SURFER_STATE_DIR" => Path.join(System.tmp_dir!(), "missing-state"),
        "SURFER_CODEX_HOME" => Path.join(System.tmp_dir!(), "missing-codex")
      })

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?

    assert_runtime_path_failure(result, "SURFER_WORKSPACE_ROOT", :missing_directory)
    assert_runtime_path_failure(result, "SURFER_LOGS_DIR", :missing_directory)
    assert_runtime_path_failure(result, "SURFER_STATE_DIR", :missing_directory)
    assert_runtime_path_failure(result, "SURFER_CODEX_HOME", :missing_directory)
  end

  test "requires writable SQLite ledger parent directory" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)

    env = Map.put(env, "SURFER_SQLITE_PATH", Path.join(System.tmp_dir!(), "missing-state/surfer.sqlite3"))

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?

    assert Enum.any?(result.failed_checks, fn
             %{name: :sqlite_path, env: "SURFER_SQLITE_PATH", reason: :missing_directory} -> true
             _check -> false
           end)
  end

  test "reports existing runtime mount paths that are not writable" do
    {env, cleanup} = required_env_with_paths()
    logs_dir = Map.fetch!(env, "SURFER_LOGS_DIR")

    on_exit(fn ->
      File.chmod(logs_dir, 0o700)
      cleanup.()
    end)

    File.chmod!(logs_dir, 0o500)

    result = LivePreflight.check(env: env, codex_check?: false)

    refute result.ok?
    assert_runtime_path_failure(result, "SURFER_LOGS_DIR", :not_writable)
  end

  defp required_env do
    %{
      "LINEAR_API_KEY" => "linear-api-key",
      "LINEAR_ACCESS_TOKEN" => "linear-access-token",
      "LINEAR_WEBHOOK_SECRET" => "linear-webhook-secret",
      "LINEAR_PROJECT_SLUG" => "coding-surfer",
      "LINEAR_TEAM_ID" => "team-1",
      "DISCORD_PUBLIC_KEY" => String.duplicate("a", 64),
      "DISCORD_MESSAGE_INGRESS_SECRET" => "discord-message-relay-secret",
      "DISCORD_APPLICATION_ID" => "app-1",
      "DISCORD_BOT_TOKEN" => "discord-bot-token",
      "DISCORD_GUILD_ID" => "guild-1",
      "DISCORD_ALLOWED_GUILDS" => "guild-1",
      "DISCORD_ALLOWED_CHANNELS" => "channel-1",
      "DISCORD_REPORT_CHANNEL_ID" => "channel-1",
      "GITHUB_TOKEN" => "github-token",
      "SURFER_REPOSITORY_URL" => "https://github.com/acme/web.git",
      "SURFER_PUBLIC_URL" => "https://surfer.example.com",
      "SURFER_SQLITE_PATH" => "/srv/surfer/state/surfer.sqlite3"
    }
  end

  defp required_env_with_paths do
    root = Path.join(System.tmp_dir!(), "surfer-live-preflight-#{System.unique_integer([:positive])}")

    paths = %{
      "SURFER_WORKSPACE_ROOT" => Path.join(root, "workspaces"),
      "SURFER_LOGS_DIR" => Path.join(root, "logs"),
      "SURFER_STATE_DIR" => Path.join(root, "state"),
      "SURFER_CODEX_HOME" => Path.join(root, "codex")
    }

    Enum.each(paths, fn {_key, path} -> File.mkdir_p!(path) end)

    env =
      required_env()
      |> Map.merge(paths)
      |> Map.put("SURFER_SQLITE_PATH", Path.join(paths["SURFER_STATE_DIR"], "surfer.sqlite3"))

    {env, fn -> File.rm_rf(root) end}
  end

  defp assert_runtime_path_failure(result, env, reason) do
    assert Enum.any?(result.failed_checks, fn
             %{name: :runtime_path, env: ^env, reason: ^reason} -> true
             _check -> false
           end)
  end
end
