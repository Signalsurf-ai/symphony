defmodule Mix.Tasks.Surfer.LivePreflightTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Surfer.LivePreflight, as: LivePreflightTask
  alias SymphonyElixir.Surfer.LivePreflight

  setup do
    Mix.Task.reenable("surfer.live_preflight")
    original_env = Map.new(LivePreflight.required_env_vars(), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "raises with explicit missing live smoke prerequisites" do
    Enum.each(LivePreflight.required_env_vars(), &System.delete_env/1)

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/surfer.live_preflight failed/, fn ->
          LivePreflightTask.run(["--skip-codex"])
        end
      end)

    assert error_output =~ "Missing required live smoke environment:"
    assert error_output =~ "LINEAR_ACCESS_TOKEN"
    assert error_output =~ "DISCORD_MESSAGE_INGRESS_SECRET"
    assert error_output =~ "DISCORD_APPLICATION_ID"
    assert error_output =~ "SURFER_PUBLIC_URL"
    assert error_output =~ "SURFER_SQLITE_PATH"
    assert error_output =~ "SURFER_WORKSPACE_ROOT"
    assert error_output =~ "SURFER_CODEX_HOME"
  end

  test "prints help" do
    output =
      capture_io(fn ->
        LivePreflightTask.run(["--help"])
      end)

    assert output =~ "mix surfer.live_preflight"
    assert output =~ "Surfer v0.1"
    refute String.contains?(output, "Surfer " <> "V" <> "0.1")
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      LivePreflightTask.run(["--wat"])
    end
  end

  test "prints success when required live smoke prerequisites are present" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    output =
      capture_io(fn ->
        assert :ok = LivePreflightTask.run(["--skip-codex"])
      end)

    assert output =~ "surfer.live_preflight: live smoke prerequisites present"
  end

  test "prints failed preflight checks" do
    {env, cleanup} = required_env_with_paths()
    on_exit(cleanup)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
    System.put_env("SURFER_PUBLIC_URL", "http://localhost:4000")
    System.put_env("SURFER_LOGS_DIR", "/missing-logs")
    System.put_env("SURFER_SQLITE_PATH", "/missing-state/surfer.sqlite3")

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/surfer.live_preflight failed/, fn ->
          LivePreflightTask.run(["--skip-codex"])
        end
      end)

    assert error_output =~ "Failed surfer_public_url: :must_be_https_url"
    assert error_output =~ "Failed runtime_path SURFER_LOGS_DIR=\"/missing-logs\": :missing_directory"
    assert error_output =~ "Failed sqlite_path SURFER_SQLITE_PATH=\"/missing-state/surfer.sqlite3\": :missing_directory"
  end

  defp required_env do
    %{
      "LINEAR_ACCESS_TOKEN" => "linear-access-token",
      "LINEAR_WEBHOOK_SECRET" => "linear-webhook-secret",
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
    root = Path.join(System.tmp_dir!(), "surfer-live-preflight-task-#{System.unique_integer([:positive])}")

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
end
