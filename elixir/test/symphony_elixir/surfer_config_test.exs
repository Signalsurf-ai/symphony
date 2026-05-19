defmodule SymphonyElixir.SurferConfigTest do
  use SymphonyElixir.TestSupport

  test "parses Surfer VPS config and resolves environment-backed values" do
    previous_discord_guild = System.get_env("DISCORD_GUILD_ID")
    previous_discord_channel = System.get_env("DISCORD_REPORT_CHANNEL_ID")
    previous_discord_public_key = System.get_env("DISCORD_PUBLIC_KEY")
    previous_discord_public_key_next = System.get_env("DISCORD_PUBLIC_KEY_NEXT")
    previous_discord_bot_token = System.get_env("DISCORD_BOT_TOKEN")
    previous_linear_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    previous_linear_secret_next = System.get_env("LINEAR_WEBHOOK_SECRET_NEXT")
    previous_linear_token = System.get_env("LINEAR_ACCESS_TOKEN")
    previous_linear_team_id = System.get_env("LINEAR_TEAM_ID")
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_external_base_url = System.get_env("SURFER_EXTERNAL_BASE_URL")
    previous_codex_home = System.get_env("SURFER_CODEX_HOME")
    previous_pause_mode = System.get_env("SURFER_PAUSE_MODE")

    on_exit(fn ->
      restore_env("DISCORD_GUILD_ID", previous_discord_guild)
      restore_env("DISCORD_REPORT_CHANNEL_ID", previous_discord_channel)
      restore_env("DISCORD_PUBLIC_KEY", previous_discord_public_key)
      restore_env("DISCORD_PUBLIC_KEY_NEXT", previous_discord_public_key_next)
      restore_env("DISCORD_BOT_TOKEN", previous_discord_bot_token)
      restore_env("LINEAR_WEBHOOK_SECRET", previous_linear_secret)
      restore_env("LINEAR_WEBHOOK_SECRET_NEXT", previous_linear_secret_next)
      restore_env("LINEAR_ACCESS_TOKEN", previous_linear_token)
      restore_env("LINEAR_TEAM_ID", previous_linear_team_id)
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("SURFER_EXTERNAL_BASE_URL", previous_external_base_url)
      restore_env("SURFER_CODEX_HOME", previous_codex_home)
      restore_env("SURFER_PAUSE_MODE", previous_pause_mode)
    end)

    System.put_env("DISCORD_GUILD_ID", "guild-1")
    System.put_env("DISCORD_REPORT_CHANNEL_ID", "channel-1")
    System.put_env("DISCORD_PUBLIC_KEY", "public-key")
    System.put_env("DISCORD_PUBLIC_KEY_NEXT", "next-public-key")
    System.put_env("DISCORD_BOT_TOKEN", "bot-token")
    System.put_env("LINEAR_WEBHOOK_SECRET", "linear-secret")
    System.put_env("LINEAR_WEBHOOK_SECRET_NEXT", "linear-secret-next")
    System.put_env("LINEAR_ACCESS_TOKEN", "linear-token")
    System.put_env("LINEAR_TEAM_ID", "team-1")
    System.put_env("GITHUB_TOKEN", "github-token")
    System.put_env("SURFER_EXTERNAL_BASE_URL", "https://surfer.example.com")
    System.put_env("SURFER_CODEX_HOME", "/srv/surfer/codex-home")
    System.put_env("SURFER_PAUSE_MODE", "cancel")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        name: Surfer
        external_base_url: $SURFER_EXTERNAL_BASE_URL
        workspace_root: /srv/surfer/workspaces
        codex:
          auth: openai_pro_oauth
          home: $SURFER_CODEX_HOME
          app_server_version: "0.131.0"
        storage:
          state_dir: /srv/surfer/state
          logs_dir: /srv/surfer/logs
          sqlite_path: /srv/surfer/state/surfer.sqlite3
        platforms:
          discord:
            enabled: true
            interactions_path: /webhooks/discord/interactions
            message_ingress_path: /webhooks/discord/message
            public_key: $DISCORD_PUBLIC_KEY
            public_key_next: $DISCORD_PUBLIC_KEY_NEXT
            bot_token: $DISCORD_BOT_TOKEN
            report_channel: $DISCORD_REPORT_CHANNEL_ID
            allowed_guilds:
              - $DISCORD_GUILD_ID
            allowed_channels:
              - channel-1
            per_user_daily_run_limit: 10
            per_channel_daily_run_limit: 25
          github:
            enabled: true
            token: $GITHUB_TOKEN
            company_brain_repo: your-org/company-brain
            company_brain_paths:
              - meetings/
              - research/
          linear:
            enabled: true
            webhook_path: /webhooks/linear/agent
            webhook_secret: $LINEAR_WEBHOOK_SECRET
            webhook_secret_next: $LINEAR_WEBHOOK_SECRET_NEXT
            access_token: $LINEAR_ACCESS_TOKEN
            team_id: $LINEAR_TEAM_ID
            project_id: project-1
        repositories:
          - key: symphony
            repo: openai/symphony
            checkout_path: /srv/surfer/repos/symphony
            default_branch: main
            workflow: ./WORKFLOW.md
            linear_team_ids:
              - $LINEAR_TEAM_ID
            discord_channel_ids:
              - $DISCORD_REPORT_CHANNEL_ID
            company_brain_paths:
              - meetings/
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    settings = Config.settings!()

    assert settings.surfer.name == "Surfer"
    assert settings.surfer.pause_mode == "cancel"
    assert settings.surfer.external_base_url == "https://surfer.example.com"
    assert settings.surfer.workspace_root == "/srv/surfer/workspaces"
    assert settings.surfer.codex.auth == "openai_pro_oauth"
    assert settings.surfer.codex.home == "/srv/surfer/codex-home"
    assert settings.surfer.codex.app_server_version == "0.131.0"
    assert settings.surfer.storage.sqlite_path == "/srv/surfer/state/surfer.sqlite3"
    assert settings.surfer.codex.health_check_command == "codex login status"
    assert settings.surfer.platforms.discord.enabled == true
    assert settings.surfer.platforms.discord.interactions_path == "/webhooks/discord/interactions"
    assert settings.surfer.platforms.discord.message_ingress_path == "/webhooks/discord/message"
    assert settings.surfer.platforms.discord.public_key == "public-key"
    assert settings.surfer.platforms.discord.public_key_next == "next-public-key"
    assert settings.surfer.platforms.discord.bot_token == "bot-token"
    assert settings.surfer.platforms.discord.report_channel == "channel-1"
    assert settings.surfer.platforms.discord.allowed_guilds == ["guild-1"]
    assert settings.surfer.platforms.discord.allowed_channels == ["channel-1"]
    assert settings.surfer.platforms.discord.per_channel_queued_limit == 3
    assert settings.surfer.platforms.discord.per_user_daily_run_limit == 10
    assert settings.surfer.platforms.discord.per_channel_daily_run_limit == 25
    assert settings.surfer.platforms.linear.webhook_secret == "linear-secret"
    assert settings.surfer.platforms.linear.webhook_secret_next == "linear-secret-next"
    assert settings.surfer.platforms.linear.access_token == "linear-token"
    assert settings.surfer.platforms.linear.team_id == "team-1"
    assert settings.surfer.platforms.linear.project_id == "project-1"
    assert settings.surfer.platforms.github.token == "github-token"
    assert settings.surfer.platforms.github.company_brain_repo == "your-org/company-brain"
    assert settings.surfer.platforms.github.company_brain_paths == ["meetings/", "research/"]

    assert [
             %{
               key: "symphony",
               name: "symphony",
               repo: "openai/symphony",
               url: "https://github.com/openai/symphony",
               checkout_path: "/srv/surfer/repos/symphony",
               linear_team_ids: ["team-1"],
               discord_channel_ids: ["channel-1"],
               company_brain_paths: ["meetings/"]
             }
           ] = settings.surfer.repositories
  end

  test "uses surfer.workspace_root as the runtime workspace root when workspace.root is omitted" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "surfer-runtime-workspace-root-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        workspace_root: #{workspace_root}
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert Config.settings!().workspace.root == workspace_root
    assert Config.settings!().surfer.workspace_root == workspace_root
    assert {:ok, workspace} = Workspace.create_for_issue("SURF-ROOT")
    assert {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)
    assert String.starts_with?(workspace, canonical_root)
  end

  test "parses PRD-style platform environment variable aliases" do
    env_values = %{
      "SURFER_TEST_LINEAR_WEBHOOK_SECRET" => "linear-secret",
      "SURFER_TEST_LINEAR_ACCESS_TOKEN" => "linear-token",
      "SURFER_TEST_LINEAR_TEAM_ID" => "team-1",
      "SURFER_TEST_LINEAR_PROJECT_ID" => "project-1",
      "SURFER_TEST_DISCORD_PUBLIC_KEY" => "discord-public-key",
      "SURFER_TEST_DISCORD_BOT_TOKEN" => "discord-bot-token",
      "SURFER_TEST_DISCORD_ALLOWED_GUILDS" => "guild-1,guild-2",
      "SURFER_TEST_DISCORD_ALLOWED_CHANNELS" => "channel-1, channel-2",
      "SURFER_TEST_DISCORD_REPORT_CHANNEL" => "channel-report",
      "SURFER_TEST_GITHUB_TOKEN" => "github-token"
    }

    previous = Map.new(Map.keys(env_values), fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    Enum.each(env_values, fn {key, value} -> System.put_env(key, value) end)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret_env: SURFER_TEST_LINEAR_WEBHOOK_SECRET
            access_token_env: SURFER_TEST_LINEAR_ACCESS_TOKEN
            team_id_env: SURFER_TEST_LINEAR_TEAM_ID
            project_id_env: SURFER_TEST_LINEAR_PROJECT_ID
          discord:
            enabled: true
            public_key_env: SURFER_TEST_DISCORD_PUBLIC_KEY
            bot_token_env: SURFER_TEST_DISCORD_BOT_TOKEN
            allowed_guilds_env: SURFER_TEST_DISCORD_ALLOWED_GUILDS
            allowed_channels_env: SURFER_TEST_DISCORD_ALLOWED_CHANNELS
            report_channel_env: SURFER_TEST_DISCORD_REPORT_CHANNEL
          github:
            enabled: true
            token_env: SURFER_TEST_GITHUB_TOKEN
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()
    settings = Config.settings!()

    assert settings.surfer.platforms.linear.webhook_secret == "linear-secret"
    assert settings.surfer.platforms.linear.access_token == "linear-token"
    assert settings.surfer.platforms.linear.team_id == "team-1"
    assert settings.surfer.platforms.linear.project_id == "project-1"
    assert settings.surfer.platforms.discord.public_key == "discord-public-key"
    assert settings.surfer.platforms.discord.bot_token == "discord-bot-token"
    assert settings.surfer.platforms.discord.allowed_guilds == ["guild-1", "guild-2"]
    assert settings.surfer.platforms.discord.allowed_channels == ["channel-1", "channel-2"]
    assert settings.surfer.platforms.discord.report_channel == "channel-report"
    assert settings.surfer.platforms.github.token == "github-token"
  end

  test "defaults Surfer direct ingress to no legacy Linear polling unless explicitly enabled" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: linear-secret
            access_token: linear-token
        storage:
          sqlite_path: /tmp/surfer.sqlite3
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert Config.settings!().polling.enabled == false

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      polling:
        enabled: true
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: linear-secret
            access_token: linear-token
        storage:
          sqlite_path: /tmp/surfer.sqlite3
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert Config.settings!().polling.enabled == true
  end

  test "resolves environment-backed tracker project slug for Surfer workflows" do
    previous_project_slug = System.get_env("LINEAR_PROJECT_SLUG")

    on_exit(fn ->
      restore_env("LINEAR_PROJECT_SLUG", previous_project_slug)
    end)

    System.put_env("LINEAR_PROJECT_SLUG", "coding-surfer")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: linear
        api_key: token
        project_slug: $LINEAR_PROJECT_SLUG
      surfer:
        workspace_root: /srv/surfer/workspaces
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert Config.settings!().tracker.project_slug == "coding-surfer"
  end

  test "rejects repository checkout paths that are not absolute" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        repositories:
          - key: web
            repo: acme/web
            checkout_path: ../web
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "surfer.repositories.checkout_path"
  end

  test "rejects unsupported Surfer Codex auth modes" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        codex:
          auth: cursor_pro_oauth
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "surfer.codex.auth"
  end

  test "fails closed when OpenAI Pro OAuth Codex config has no app-server version pin" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        codex:
          auth: openai_pro_oauth
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "surfer.codex.app_server_version"
  end

  test "fails closed when SURFER_PAUSE_MODE env is unsupported" do
    previous_pause_mode = System.get_env("SURFER_PAUSE_MODE")
    on_exit(fn -> restore_env("SURFER_PAUSE_MODE", previous_pause_mode) end)
    System.put_env("SURFER_PAUSE_MODE", "panic")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:invalid_surfer_pause_mode, "panic"}} = Config.validate!()
  end

  test "SURFER_PAUSED env cannot unpause configured Surfer pause" do
    previous_paused = System.get_env("SURFER_PAUSED")
    on_exit(fn -> restore_env("SURFER_PAUSED", previous_paused) end)
    System.put_env("SURFER_PAUSED", "false")

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        paused: true
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert Config.settings!().surfer.paused == true
  end

  test "fails closed when enabled Surfer platform secrets are missing" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
          discord:
            enabled: true
          github:
            enabled: true
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:missing_surfer_platform_secret, :linear, :webhook_secret}} = Config.validate!()
  end

  test "fails closed when GitHub App auth is configured for Surfer v0.1" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          github:
            enabled: true
            app_id: "12345"
            private_key: "-----BEGIN PRIVATE KEY-----"
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "surfer.platforms.github.app_id"
    assert message =~ "GitHub App auth is not supported in Surfer v0.1"
  end

  test "fails closed when enabled Surfer platforms have no SQLite ledger path" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          linear:
            enabled: true
            webhook_secret: linear-secret
            access_token: linear-token
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:missing_surfer_storage_path, :sqlite_path}} = Config.validate!()
  end

  test "application boot fails closed before supervisors start when enabled Surfer secrets are missing" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      surfer:
        platforms:
          discord:
            enabled: true
      ---
      Prompt
      """
    )

    WorkflowStore.force_reload()

    assert {:error, {:missing_surfer_platform_secret, :discord, :public_key}} =
             SymphonyElixir.Application.start(:normal, [])
  end
end
