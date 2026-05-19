defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Surfer do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    defmodule Codex do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:auth, :string)
        field(:home, :string)
        field(:app_server_version, :string)
        field(:health_check_command, :string, default: "codex login status")
        field(:per_run_budget_usd, :float)
        field(:daily_budget_usd, :float)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        fields = [
          :auth,
          :home,
          :app_server_version,
          :health_check_command,
          :per_run_budget_usd,
          :daily_budget_usd
        ]

        schema
        |> cast(attrs, fields, empty_values: [])
        |> validate_required(:health_check_command)
        |> validate_inclusion(:auth, ["openai_pro_oauth"])
        |> validate_number(:per_run_budget_usd, greater_than: 0)
        |> validate_number(:daily_budget_usd, greater_than: 0)
      end
    end

    defmodule Storage do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:state_dir, :string)
        field(:logs_dir, :string)
        field(:sqlite_path, :string)
        field(:retention_days, :integer, default: 90)
        field(:workspace_retention_days, :integer, default: 14)
        field(:disk_pressure_max_used_percent, :integer)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [
            :state_dir,
            :logs_dir,
            :sqlite_path,
            :retention_days,
            :workspace_retention_days,
            :disk_pressure_max_used_percent
          ],
          empty_values: []
        )
        |> validate_number(:retention_days, greater_than: 0)
        |> validate_number(:workspace_retention_days, greater_than: 0)
        |> validate_number(:disk_pressure_max_used_percent, greater_than: 0, less_than_or_equal_to: 100)
      end
    end

    defmodule Discord do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:interactions_path, :string, default: "/webhooks/discord/interactions")
        field(:message_ingress_path, :string, default: "/webhooks/discord/message")
        field(:public_key, :string)
        field(:public_key_env, :string)
        field(:public_key_next, :string)
        field(:public_key_next_env, :string)
        field(:bot_token, :string)
        field(:bot_token_env, :string)
        field(:report_channel, :string)
        field(:report_channel_env, :string)
        field(:allowed_guilds, {:array, :string}, default: [])
        field(:allowed_guilds_env, :string)
        field(:allowed_channels, {:array, :string}, default: [])
        field(:allowed_channels_env, :string)
        field(:signature_max_age_seconds, :integer, default: 300)
        field(:per_user_cooldown_seconds, :integer, default: 30)
        field(:per_channel_queued_limit, :integer, default: 3)
        field(:per_user_daily_run_limit, :integer)
        field(:per_channel_daily_run_limit, :integer)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [
            :enabled,
            :interactions_path,
            :message_ingress_path,
            :public_key,
            :public_key_env,
            :public_key_next,
            :public_key_next_env,
            :bot_token,
            :bot_token_env,
            :report_channel,
            :report_channel_env,
            :allowed_guilds,
            :allowed_guilds_env,
            :allowed_channels,
            :allowed_channels_env,
            :signature_max_age_seconds,
            :per_user_cooldown_seconds,
            :per_channel_queued_limit,
            :per_user_daily_run_limit,
            :per_channel_daily_run_limit
          ],
          empty_values: []
        )
        |> validate_number(:signature_max_age_seconds, greater_than: 0)
        |> validate_number(:per_user_cooldown_seconds, greater_than: 0)
        |> validate_number(:per_channel_queued_limit, greater_than: 0)
        |> validate_number(:per_user_daily_run_limit, greater_than: 0)
        |> validate_number(:per_channel_daily_run_limit, greater_than: 0)
      end
    end

    defmodule GitHub do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:token, :string)
        field(:token_env, :string)
        field(:company_brain_repo, :string)
        field(:company_brain_paths, {:array, :string}, default: [])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        cast(schema, attrs, [:enabled, :token, :token_env, :company_brain_repo, :company_brain_paths], empty_values: [])
      end
    end

    defmodule Linear do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:webhook_path, :string, default: "/webhooks/linear/agent")
        field(:webhook_secret, :string)
        field(:webhook_secret_env, :string)
        field(:webhook_secret_next, :string)
        field(:webhook_secret_next_env, :string)
        field(:access_token, :string)
        field(:access_token_env, :string)
        field(:team_id, :string)
        field(:team_id_env, :string)
        field(:project_id, :string)
        field(:project_id_env, :string)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        fields = [
          :enabled,
          :webhook_path,
          :webhook_secret,
          :webhook_secret_env,
          :webhook_secret_next,
          :webhook_secret_next_env,
          :access_token,
          :access_token_env,
          :team_id,
          :team_id_env,
          :project_id,
          :project_id_env
        ]

        cast(
          schema,
          attrs,
          fields,
          empty_values: []
        )
      end
    end

    defmodule Platforms do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        embeds_one(:discord, Discord, on_replace: :update, defaults_to_struct: true)
        embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
        embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [])
        |> cast_embed(:discord, with: &Discord.changeset/2)
        |> cast_embed(:github, with: &GitHub.changeset/2)
        |> cast_embed(:linear, with: &Linear.changeset/2)
      end
    end

    defmodule Repository do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:key, :string)
        field(:name, :string)
        field(:repo, :string)
        field(:url, :string)
        field(:checkout_path, :string)
        field(:default_branch, :string)
        field(:workflow, :string)
        field(:linear_team_ids, {:array, :string}, default: [])
        field(:discord_channel_ids, {:array, :string}, default: [])
        field(:company_brain_paths, {:array, :string}, default: [])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [
            :key,
            :name,
            :repo,
            :url,
            :checkout_path,
            :default_branch,
            :workflow,
            :linear_team_ids,
            :discord_channel_ids,
            :company_brain_paths
          ],
          empty_values: []
        )
        |> validate_checkout_path()
      end

      defp validate_checkout_path(changeset) do
        validate_change(changeset, :checkout_path, fn :checkout_path, path ->
          if is_binary(path) and Path.type(path) != :absolute do
            [checkout_path: "must be an absolute path"]
          else
            []
          end
        end)
      end
    end

    embedded_schema do
      field(:name, :string, default: "Surfer")
      field(:paused, :boolean, default: false)
      field(:pause_mode, :string, default: "drain")
      field(:external_base_url, :string)
      field(:workspace_root, :string)
      embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
      embeds_one(:storage, Storage, on_replace: :update, defaults_to_struct: true)
      embeds_one(:platforms, Platforms, on_replace: :update, defaults_to_struct: true)
      embeds_many(:repositories, Repository, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:name, :paused, :pause_mode, :external_base_url, :workspace_root], empty_values: [])
      |> validate_inclusion(:pause_mode, ["drain", "cancel"])
      |> cast_embed(:codex, with: &Codex.changeset/2)
      |> cast_embed(:storage, with: &Storage.changeset/2)
      |> cast_embed(:platforms, with: &Platforms.changeset/2)
      |> cast_embed(:repositories, with: &Repository.changeset/2)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:surfer, Surfer, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config = config |> normalize_keys() |> drop_nil_values()
    polling_enabled_configured? = polling_enabled_configured?(config)

    config
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings, polling_enabled_configured?: polling_enabled_configured?)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:surfer, with: &Surfer.changeset/2)
  end

  defp finalize_settings(settings, opts) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        project_slug: resolve_secret_setting(settings.tracker.project_slug, System.get_env("LINEAR_PROJECT_SLUG")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    surfer = finalize_surfer(settings.surfer, tracker.api_key)
    polling = default_surfer_polling(settings.polling, surfer, Keyword.fetch!(opts, :polling_enabled_configured?))
    default_workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")
    surfer_workspace_root = resolve_path_value(surfer.workspace_root, nil)

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, surfer_workspace_root || default_workspace_root)
    }

    surfer = %{surfer | workspace_root: surfer_workspace_root || workspace.root}

    %{settings | tracker: tracker, polling: polling, workspace: workspace, codex: codex, surfer: surfer}
  end

  defp polling_enabled_configured?(%{"polling" => %{} = polling}), do: Map.has_key?(polling, "enabled")
  defp polling_enabled_configured?(_config), do: false

  defp default_surfer_polling(polling, surfer, false) do
    if surfer_direct_ingress_enabled?(surfer), do: %{polling | enabled: false}, else: polling
  end

  defp default_surfer_polling(polling, _surfer, true), do: polling

  defp surfer_direct_ingress_enabled?(%Surfer{} = surfer) do
    surfer.platforms.linear.enabled == true or surfer.platforms.discord.enabled == true
  end

  defp finalize_surfer(%Surfer{} = surfer, linear_access_token_fallback) do
    platforms = surfer.platforms

    codex = %{
      surfer.codex
      | home: resolve_env_value_or_nil(surfer.codex.home) || System.get_env("SURFER_CODEX_HOME"),
        app_server_version: resolve_env_value_or_nil(surfer.codex.app_server_version)
    }

    discord_report_channel =
      resolve_secret_alias(platforms.discord.report_channel, platforms.discord.report_channel_env, nil)

    discord_public_key =
      resolve_secret_alias(platforms.discord.public_key, platforms.discord.public_key_env, nil)

    discord_public_key_next =
      resolve_secret_alias(platforms.discord.public_key_next, platforms.discord.public_key_next_env, nil)

    discord_bot_token =
      resolve_secret_alias(platforms.discord.bot_token, platforms.discord.bot_token_env, nil)

    allowed_guilds =
      resolve_env_list_alias(platforms.discord.allowed_guilds, platforms.discord.allowed_guilds_env)

    allowed_channels =
      resolve_env_list_alias(platforms.discord.allowed_channels, platforms.discord.allowed_channels_env)

    discord = %{
      platforms.discord
      | report_channel: discord_report_channel,
        public_key: discord_public_key,
        public_key_next: discord_public_key_next,
        bot_token: discord_bot_token,
        allowed_guilds: allowed_guilds,
        allowed_channels: allowed_channels
    }

    linear_webhook_secret =
      resolve_secret_alias(platforms.linear.webhook_secret, platforms.linear.webhook_secret_env, nil)

    linear_webhook_secret_next =
      resolve_secret_alias(
        platforms.linear.webhook_secret_next,
        platforms.linear.webhook_secret_next_env,
        nil
      )

    linear_access_token =
      resolve_secret_alias(
        platforms.linear.access_token,
        platforms.linear.access_token_env,
        linear_access_token_fallback
      )

    linear = %{
      platforms.linear
      | webhook_secret: linear_webhook_secret,
        webhook_secret_next: linear_webhook_secret_next,
        access_token: linear_access_token,
        team_id: resolve_secret_alias(platforms.linear.team_id, platforms.linear.team_id_env, nil),
        project_id: resolve_secret_alias(platforms.linear.project_id, platforms.linear.project_id_env, nil)
    }

    github = %{
      platforms.github
      | token: resolve_secret_alias(platforms.github.token, platforms.github.token_env, nil)
    }

    paused =
      case System.get_env("SURFER_PAUSED") do
        value when is_binary(value) -> surfer.paused or truthy_env?(value)
        _ -> surfer.paused
      end

    pause_mode =
      case System.get_env("SURFER_PAUSE_MODE") do
        value when is_binary(value) -> value |> String.downcase() |> String.trim()
        _ -> surfer.pause_mode || "drain"
      end

    platforms = %{platforms | discord: discord, github: github, linear: linear}

    %{
      surfer
      | paused: paused,
        pause_mode: pause_mode,
        external_base_url: normalize_external_base_url(resolve_env_value_or_nil(surfer.external_base_url)),
        codex: codex,
        platforms: platforms,
        repositories: Enum.map(surfer.repositories, &finalize_repository/1)
    }
  end

  defp finalize_repository(%Surfer.Repository{} = repository) do
    raw_url = resolve_env_value_or_nil(repository.url)
    repo = resolve_env_value_or_nil(repository.repo) || repo_from_url(raw_url)
    key = resolve_env_value_or_nil(repository.key) || resolve_env_value_or_nil(repository.name) || repo_slug(repo)
    name = resolve_env_value_or_nil(repository.name) || key
    url = raw_url || github_https_url(repo)

    %{
      repository
      | key: key,
        name: name,
        repo: repo,
        url: url,
        checkout_path: resolve_env_value_or_nil(repository.checkout_path),
        default_branch: resolve_env_value_or_nil(repository.default_branch),
        workflow: resolve_env_value_or_nil(repository.workflow),
        linear_team_ids: resolve_env_list(repository.linear_team_ids),
        discord_channel_ids: resolve_env_list(repository.discord_channel_ids),
        company_brain_paths: resolve_env_list(repository.company_brain_paths)
    }
  end

  defp resolve_env_value_or_nil(value) when is_binary(value), do: resolve_env_value(value, nil)
  defp resolve_env_value_or_nil(_value), do: nil

  defp repo_from_url("https://github.com/" <> repo), do: String.trim_trailing(repo, ".git")
  defp repo_from_url("git@github.com:" <> repo), do: String.trim_trailing(repo, ".git")
  defp repo_from_url(_url), do: nil

  defp repo_slug(repo) when is_binary(repo) do
    repo
    |> String.split("/")
    |> List.last()
  end

  defp repo_slug(_repo), do: nil

  defp github_https_url(repo) when is_binary(repo) and repo != "", do: "https://github.com/#{repo}"
  defp github_https_url(_repo), do: nil

  defp normalize_external_base_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_external_base_url(_url), do: nil

  defp truthy_env?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized in ["1", "true", "yes", "on"]
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_alias(value, env_name, fallback) do
    resolve_secret_setting(value, nil) ||
      resolve_env_name_secret(env_name) ||
      normalize_secret_value(fallback)
  end

  defp resolve_env_name_secret(env_name) do
    env_name
    |> env_name_value()
    |> normalize_secret_value()
  end

  defp resolve_env_list_alias(values, env_name) do
    case resolve_env_list(values) do
      [] -> resolve_env_name_list(env_name)
      resolved -> resolved
    end
  end

  defp resolve_env_name_list(env_name) do
    case env_name_value(env_name) do
      value when is_binary(value) ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _value ->
        []
    end
  end

  defp env_name_value(env_name) when is_binary(env_name) do
    case String.trim(env_name) do
      "" ->
        nil

      "$" <> _rest = env_ref ->
        resolve_env_value(env_ref, nil)

      name ->
        System.get_env(name)
    end
  end

  defp env_name_value(_env_name), do: nil

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp resolve_env_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) -> resolve_env_value(value, nil)
      value -> value
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp resolve_env_list(_values), do: []

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [prefix <> " " <> error]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
