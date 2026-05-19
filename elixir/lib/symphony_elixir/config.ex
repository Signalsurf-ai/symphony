defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec validate_startup!() :: :ok | {:error, term()}
  def validate_startup! do
    with {:ok, settings} <- settings() do
      with :ok <- validate_surfer_platforms(settings.surfer.platforms) do
        validate_surfer_storage(settings.surfer)
      end
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_tracker(settings.tracker),
         :ok <- validate_surfer_platforms(settings.surfer.platforms) do
      validate_surfer_storage(settings.surfer)
    end
  end

  defp validate_tracker(tracker) do
    cond do
      is_nil(tracker.kind) -> {:error, :missing_tracker_kind}
      tracker.kind not in ["linear", "memory"] -> {:error, {:unsupported_tracker_kind, tracker.kind}}
      tracker.kind == "linear" and not is_binary(tracker.api_key) -> {:error, :missing_linear_api_token}
      tracker.kind == "linear" and not is_binary(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> :ok
    end
  end

  defp validate_surfer_platforms(platforms) do
    Enum.find_value(
      [
        {:linear, :webhook_secret, platforms.linear.enabled, platforms.linear.webhook_secret},
        {:linear, :access_token, platforms.linear.enabled, platforms.linear.access_token},
        {:discord, :public_key, platforms.discord.enabled, platforms.discord.public_key},
        {:discord, :bot_token, platforms.discord.enabled, platforms.discord.bot_token},
        {:github, :token, platforms.github.enabled, platforms.github.token}
      ],
      :ok,
      fn {platform, field, enabled?, value} ->
        if enabled? == true and blank?(value) do
          {:error, {:missing_surfer_platform_secret, platform, field}}
        end
      end
    )
  end

  defp validate_surfer_storage(surfer) do
    if surfer_platform_enabled?(surfer.platforms) and blank?(surfer.storage.sqlite_path) do
      {:error, {:missing_surfer_storage_path, :sqlite_path}}
    else
      :ok
    end
  end

  defp surfer_platform_enabled?(platforms) do
    Enum.any?([platforms.linear, platforms.discord, platforms.github], &(&1.enabled == true))
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
