defmodule SymphonyElixir.Surfer.RunRequest do
  @moduledoc """
  Normalized Surfer request model shared by platform ingress and direct dispatch.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Surfer.SecretRedactor

  @prompt_context_max_chars 4_000
  @linear_agent_session_actions ~w(created prompted)

  defstruct [
    :run_id,
    :source,
    :request,
    :lineage,
    :routing,
    :context,
    :constraints,
    :issue,
    :organization_id
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          source: map(),
          request: map(),
          lineage: map(),
          routing: map(),
          context: map(),
          constraints: map(),
          issue: Issue.t() | nil,
          organization_id: String.t() | nil
        }

  @spec from_linear_agent_session_event(map()) :: {:ok, t()} | {:error, term()}
  def from_linear_agent_session_event(payload) when is_map(payload) do
    action = Map.get(payload, "action")

    with :ok <- validate_linear_event_type(Map.get(payload, "type")),
         :ok <- validate_linear_agent_session_action(action) do
      session = Map.get(payload, "agentSession", %{})
      issue_payload = Map.get(session, "issue", %{})
      comment = Map.get(session, "comment", %{})
      agent_activity = Map.get(session, "agentActivity") || Map.get(payload, "agentActivity") || %{}
      issue = linear_issue(issue_payload)
      prompt_context = Map.get(session, "promptContext")
      directive = linear_directive_text(action, comment, agent_activity, prompt_context)
      {request_mode, trigger_type} = classify_linear_request(directive)

      with {:ok, natural_event_key} <-
             linear_natural_event_key(session, action, comment, agent_activity, issue, request_mode),
           :ok <- validate_linear_prompted_directive(action, directive) do
        {:ok,
         %__MODULE__{
           run_id: new_run_id(),
           source: %{
             platform: :linear,
             trigger_type: trigger_type,
             raw_event_id: Map.get(payload, "webhookId"),
             actor_id: linear_actor_id(payload),
             organization_id: Map.get(payload, "organizationId"),
             action: action,
             natural_event_key: natural_event_key
           },
           request: %{
             mode: request_mode,
             trigger_type: trigger_type,
             title: linear_request_title(issue, directive),
             body: linear_request_body(request_mode, action, issue, directive, comment),
             prompt_context: prompt_context,
             requested_by: nil
           },
           lineage: %{
             linear: %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               team_id: get_in(issue_payload, ["team", "id"]),
               agent_session_id: Map.get(session, "id"),
               comment_id: Map.get(comment, "id"),
               agent_activity_id: Map.get(agent_activity, "id")
             },
             discord: %{},
             github: %{}
           },
           routing: %{},
           context: %{
             prompt_context: prompt_context,
             company_brain_refs: []
           },
           constraints: constraints_for(request_mode, :linear),
           issue: issue,
           organization_id: Map.get(payload, "organizationId")
         }}
      end
    end
  end

  @spec from_discord_message(map()) :: {:ok, t()} | {:error, term()}
  def from_discord_message(message) when is_map(message) do
    content = Map.get(message, "content", "")
    mode = discord_request_mode(content)

    with {:ok, natural_event_key} <- discord_message_natural_event_key(message, mode) do
      {:ok,
       %__MODULE__{
         run_id: new_run_id(),
         source: %{
           platform: :discord,
           trigger_type: :message,
           raw_event_id: Map.get(message, "id"),
           actor_id: get_in(message, ["author", "id"]),
           natural_event_key: natural_event_key
         },
         request: %{
           mode: mode,
           trigger_type: :message,
           title: discord_title(content, mode),
           body: content,
           prompt_context: content,
           requested_by: get_in(message, ["author", "id"])
         },
         lineage: %{
           linear: %{},
           discord: %{
             guild_id: Map.get(message, "guild_id"),
             channel_id: Map.get(message, "channel_id"),
             thread_id: Map.get(message, "thread_id"),
             message_id: Map.get(message, "id")
           },
           github: %{}
         },
         routing: %{},
         context: %{prompt_context: content, company_brain_refs: []},
         constraints: constraints_for(mode, :discord),
         issue: nil,
         organization_id: nil
       }}
    end
  end

  @spec constraints_for(atom() | String.t()) :: map()
  def constraints_for(mode), do: constraints_for(mode, nil)

  @spec constraints_for(atom() | String.t(), atom() | nil) :: map()
  def constraints_for(mode, _platform) when mode in [:code_question, "code_question"] do
    %{read_only: true, require_linear_issue: false, allow_pr_creation: false}
  end

  def constraints_for(mode, :linear) when mode in [:durable_task, "durable_task"] do
    %{read_only: false, require_linear_issue: true, allow_pr_creation: true}
  end

  def constraints_for(mode, _platform) when mode in [:durable_task, "durable_task"] do
    %{read_only: false, require_linear_issue: false, allow_pr_creation: true}
  end

  def constraints_for(mode, _platform) when mode in [:issue_create, "issue_create"] do
    %{read_only: false, require_linear_issue: false, allow_pr_creation: false}
  end

  def constraints_for(mode, _platform) when mode in [:lifecycle_control, "lifecycle_control"] do
    %{read_only: false, require_linear_issue: false, allow_pr_creation: false}
  end

  def constraints_for(_mode, _platform), do: %{read_only: true, require_linear_issue: false, allow_pr_creation: false}

  @spec route(t(), [map()]) :: {:ok, t()} | {:error, term()}
  def route(%__MODULE__{} = request, repositories) when is_list(repositories) do
    case resolve_repository(request, repositories) do
      {:ok, repository, confidence, reason} ->
        {:ok, apply_repository_route(request, repository, confidence, reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec idempotency_key(t()) :: String.t()
  def idempotency_key(%__MODULE__{source: %{natural_event_key: key}}) when is_binary(key), do: key

  def idempotency_key(%__MODULE__{
        source: %{platform: :discord},
        lineage: %{discord: %{interaction_id: interaction_id}},
        request: %{mode: mode}
      })
      when is_binary(interaction_id) do
    Enum.map_join(["discord_interaction", interaction_id, mode], ":", &to_string/1)
  end

  def idempotency_key(%__MODULE__{
        source: %{platform: :discord},
        lineage: %{discord: %{guild_id: guild_id, channel_id: channel_id, message_id: message_id}},
        request: %{mode: mode}
      })
      when is_binary(guild_id) and is_binary(channel_id) and is_binary(message_id) do
    Enum.map_join(["discord_message", guild_id, channel_id, message_id, mode], ":", &to_string/1)
  end

  def idempotency_key(%__MODULE__{source: %{platform: platform, raw_event_id: raw_event_id}, request: %{mode: mode}}) do
    Enum.map_join([platform, raw_event_id, mode], ":", &to_string/1)
  end

  @spec surfer_context(t()) :: map()
  def surfer_context(%__MODULE__{} = request) do
    context = request.context || %{}

    %{
      run_id: request.run_id,
      request_mode: to_string(request.request.mode),
      source_platform: to_string(request.source.platform),
      source: prompt_safe_source(request.source),
      trigger_type: to_string(request.source.trigger_type),
      organization_id: request.organization_id,
      lineage: request.lineage,
      linear: request.lineage.linear,
      discord: request.lineage.discord,
      github: request.lineage.github,
      routing: request.routing,
      constraints: request.constraints || %{},
      prompt_context: sanitize_prompt_context(context_value(context, :prompt_context)),
      company_brain_refs: context_value(context, :company_brain_refs) || []
    }
  end

  defp context_value(context, key) when is_map(context), do: Map.get(context, key) || Map.get(context, to_string(key))

  defp prompt_safe_source(source) when is_map(source) do
    %{
      platform: source |> Map.get(:platform) |> to_string_or_nil(),
      trigger_type: source |> Map.get(:trigger_type) |> to_string_or_nil(),
      raw_event_id: Map.get(source, :raw_event_id),
      actor_id: Map.get(source, :actor_id),
      organization_id: Map.get(source, :organization_id),
      action: Map.get(source, :action),
      natural_event_key: Map.get(source, :natural_event_key)
    }
  end

  defp prompt_safe_source(_source), do: %{}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp sanitize_prompt_context(nil), do: nil

  defp sanitize_prompt_context(value) when is_binary(value) do
    value
    |> redact_prompt_context()
    |> bound_prompt_context()
  end

  defp sanitize_prompt_context(_value), do: nil

  defp validate_linear_event_type(nil), do: {:error, :missing_linear_event_type}
  defp validate_linear_event_type("AgentSessionEvent"), do: :ok
  defp validate_linear_event_type(type), do: {:error, {:unsupported_linear_event_type, type}}

  defp validate_linear_agent_session_action(nil), do: {:error, :missing_linear_agent_action}

  defp validate_linear_agent_session_action(action) when action in @linear_agent_session_actions, do: :ok

  defp validate_linear_agent_session_action(action), do: {:error, {:unsupported_linear_agent_action, action}}

  defp validate_linear_prompted_directive("prompted", directive) when is_binary(directive) do
    if String.trim(directive) == "" do
      {:error, :missing_linear_prompted_directive}
    else
      :ok
    end
  end

  defp validate_linear_prompted_directive("prompted", _directive), do: {:error, :missing_linear_prompted_directive}
  defp validate_linear_prompted_directive(_action, _directive), do: :ok

  defp linear_directive_text("prompted", comment, agent_activity, prompt_context) do
    first_present([
      map_text(agent_activity, "body"),
      map_text(agent_activity, "content"),
      map_text(comment, "body"),
      primary_directive_text(prompt_context)
    ])
  end

  defp linear_directive_text(_action, comment, agent_activity, prompt_context) do
    first_present([
      map_text(comment, "body"),
      primary_directive_text(prompt_context),
      map_text(agent_activity, "body"),
      map_text(agent_activity, "content")
    ])
  end

  defp linear_actor_id(payload) do
    first_present([
      get_in(payload, ["actor", "id"]),
      Map.get(payload, "actorId"),
      Map.get(payload, "userId")
    ])
  end

  defp classify_linear_request(directive) do
    directive = directive || ""

    cond do
      String.trim(directive) == "" -> {:durable_task, :delegation}
      linear_advisory_question?(directive) -> {:code_question, :mention}
      linear_implementation_request?(directive) -> {:durable_task, :delegation}
      true -> {:code_question, :mention}
    end
  end

  defp linear_request_title(issue, directive) do
    first_present([issue.title, directive]) || "Linear request"
  end

  defp linear_request_body(:code_question, _action, issue, directive, comment) do
    first_present([directive, map_text(comment, "body"), issue.description, issue.title])
  end

  defp linear_request_body(:durable_task, "prompted", issue, directive, comment) do
    first_present([directive, map_text(comment, "body"), issue.description, issue.title])
  end

  defp linear_request_body(:durable_task, _action, issue, directive, comment) do
    first_present([issue.description, directive, map_text(comment, "body"), issue.title])
  end

  defp linear_advisory_question?(directive) do
    normalized = normalize_directive(directive)

    Regex.match?(
      ~r/\A(what|where|when|why|which|who|whose|how|can you explain|could you explain|please explain|explain|show me|walk me through|help me understand|what would|how would|how should|should we|can we|could we|would it|is it|are there|do we|does this|tell me)\b/,
      normalized
    )
  end

  defp linear_implementation_request?(directive) do
    normalized = normalize_directive(directive)

    Regex.match?(
      ~r/\b(implement|fix|build|add|update|change|refactor|create|write|code|patch|repair|solve|resolve|address|ship|land|open pr|raise pr|create pr|submit pr|make a pr|work on|take over|handle this)\b/,
      normalized
    )
  end

  defp normalize_directive(directive) do
    directive
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9+#._-]+/u, " ")
    |> String.trim()
  end

  defp primary_directive_text(value) when is_binary(value) do
    case Regex.run(~r/<primary-directive-thread[^>]*>(.*?)<\/primary-directive-thread>/is, value, capture: :all_but_first) do
      [body] -> strip_markup(body)
      _no_directive -> nil
    end
  end

  defp primary_directive_text(_value), do: nil

  defp strip_markup(value) do
    value
    |> String.replace(~r/<[^>]+>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp map_text(map, key) when is_map(map) do
    map
    |> Map.get(key)
    |> case do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      _value -> nil
    end
  end

  defp map_text(_map, _key), do: nil

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value |> String.trim() |> blank_to_nil()

      _value ->
        nil
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp redact_prompt_context(value) do
    SecretRedactor.redact_text(value)
  end

  defp bound_prompt_context(value) do
    if String.length(value) > @prompt_context_max_chars do
      String.slice(value, 0, @prompt_context_max_chars) <> "\n[truncated]"
    else
      value
    end
  end

  defp linear_issue(payload) when is_map(payload) do
    %Issue{
      id: Map.get(payload, "id"),
      identifier: Map.get(payload, "identifier"),
      title: Map.get(payload, "title"),
      description: Map.get(payload, "description"),
      priority: Map.get(payload, "priority"),
      state: get_in(payload, ["state", "name"]),
      branch_name: Map.get(payload, "branchName"),
      url: Map.get(payload, "url"),
      labels: linear_label_names(Map.get(payload, "labels"))
    }
  end

  defp linear_label_names(%{"nodes" => labels}) when is_list(labels) do
    labels
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp linear_label_names(_labels), do: []

  defp discord_request_mode(content) when is_binary(content) do
    normalized = String.downcase(content)

    cond do
      String.contains?(normalized, "create issue") -> :issue_create
      String.contains?(normalized, "implement") -> :durable_task
      String.contains?(normalized, "fix") -> :durable_task
      true -> :code_question
    end
  end

  defp discord_message_natural_event_key(message, mode) do
    with {:ok, guild_id} <- required_key_part(Map.get(message, "guild_id"), :missing_discord_guild_id),
         {:ok, channel_id} <- required_key_part(Map.get(message, "channel_id"), :missing_discord_channel_id),
         {:ok, message_id} <- required_key_part(Map.get(message, "id"), :missing_discord_message_id) do
      {:ok, Enum.map_join(["discord_message", guild_id, channel_id, message_id, mode], ":", &to_string/1)}
    end
  end

  defp linear_natural_event_key(session, "prompted", _comment, agent_activity, _issue, mode) do
    with {:ok, session_id} <- required_key_part(Map.get(session, "id"), :missing_linear_agent_session_id),
         {:ok, activity_id} <- required_key_part(Map.get(agent_activity, "id"), :missing_linear_agent_activity_id) do
      {:ok, Enum.map_join(["linear", session_id, "prompted", activity_id, mode], ":", &to_string/1)}
    end
  end

  defp linear_natural_event_key(session, action, comment, _agent_activity, issue, mode) do
    with {:ok, session_id} <- required_key_part(Map.get(session, "id"), :missing_linear_agent_session_id),
         {:ok, subject_id} <- required_key_part(Map.get(comment, "id") || issue.id, :missing_linear_issue_or_comment_id) do
      {:ok, Enum.map_join(["linear", session_id, action || "created", subject_id, mode], ":", &to_string/1)}
    end
  end

  defp required_key_part(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required_key_part(_value, reason), do: {:error, reason}

  defp discord_title(content, :issue_create), do: content |> strip_command_prefix() |> blank_to_default("Discord request")
  defp discord_title(content, _mode), do: content |> String.trim() |> blank_to_default("Discord request")

  defp strip_command_prefix(content) do
    content
    |> String.replace(~r/^surfer\s+create\s+issue:\s*/i, "")
    |> String.trim()
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp resolve_repository(%__MODULE__{} = request, repositories) do
    normalized = Enum.map(repositories, &normalize_repository/1)
    explicit = routing_value(request.routing, :repository_key) || routing_value(request.routing, :repository)

    if explicit do
      resolve_explicit_repository(explicit, normalized)
    else
      case resolve_source_hint(request, normalized) do
        {:ok, repository, confidence, reason} ->
          {:ok, repository, confidence, reason}

        :no_match ->
          fallback_repository(normalized)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_explicit_repository(name, repositories) when is_binary(name) do
    repositories
    |> Enum.find(&(name in [identity_value(&1.key), identity_value(&1.name), identity_value(&1.repo)]))
    |> case do
      nil -> {:error, {:unknown_repository, name}}
      repository -> {:ok, repository, :explicit, "Explicit repository routing matched #{repository.key}."}
    end
  end

  defp resolve_source_hint(%__MODULE__{lineage: %{linear: %{team_id: team_id}}}, repositories) when is_binary(team_id) do
    repositories
    |> Enum.filter(&(team_id in &1.linear_team_ids))
    |> repository_match_result("Linear team id #{team_id} matched repository config.")
  end

  defp resolve_source_hint(%__MODULE__{lineage: %{discord: %{channel_id: channel_id}}}, repositories)
       when is_binary(channel_id) do
    repositories
    |> Enum.filter(&(channel_id in &1.discord_channel_ids))
    |> repository_match_result("Discord channel id #{channel_id} matched repository config.")
  end

  defp resolve_source_hint(_request, _repositories), do: :no_match

  defp repository_match_result([repository], reason), do: {:ok, repository, :source_hint, reason}
  defp repository_match_result([], _reason), do: :no_match
  defp repository_match_result(repositories, _reason), do: {:error, {:ambiguous_repository, Enum.map(repositories, & &1.key)}}

  defp fallback_repository([]), do: {:error, {:ambiguous_repository, []}}
  defp fallback_repository([repository]), do: {:ok, repository, :fallback, "Only configured repository."}
  defp fallback_repository(repositories), do: {:error, {:ambiguous_repository, Enum.map(repositories, & &1.key)}}

  defp normalize_repository(repository) when is_map(repository) do
    {repo, key, name, url} = repository_identity(repository)

    %{
      key: key,
      name: name,
      repo: repo,
      url: url
    }
    |> Map.merge(repository_runtime_metadata(repository))
  end

  defp repository_identity(repository) do
    repo = repository_value(repository, :repo) || repo_from_url(repository_value(repository, :url))
    key = repository_value(repository, :key) || repository_value(repository, :name) || repo_slug(repo)
    name = repository_value(repository, :name) || key
    url = repository_value(repository, :url) || github_https_url(repo)

    {repo, key, name, url}
  end

  defp repository_runtime_metadata(repository) do
    %{
      checkout_path: repository_value(repository, :checkout_path),
      workflow: repository_value(repository, :workflow) || "./WORKFLOW.md",
      default_branch: repository_value(repository, :default_branch),
      linear_team_ids: repository_value(repository, :linear_team_ids) || [],
      discord_channel_ids: repository_value(repository, :discord_channel_ids) || [],
      company_brain_paths: repository_value(repository, :company_brain_paths) || []
    }
  end

  defp repository_value(repository, key), do: Map.get(repository, key) || Map.get(repository, to_string(key))

  defp routing_value(nil, _key), do: nil
  defp routing_value(routing, key) when is_map(routing), do: Map.get(routing, key) || Map.get(routing, to_string(key))

  defp identity_value(value) when is_binary(value), do: value
  defp identity_value(_value), do: nil

  defp apply_repository_route(request, repository, confidence, reason) do
    routing = %{
      repository: repository.key,
      repository_key: repository.key,
      repository_full_name: repository.repo,
      repository_url: repository.url,
      checkout_path: repository.checkout_path,
      workflow_path: repository.workflow,
      branch_hint: repository.default_branch,
      confidence: confidence,
      reason: reason,
      company_brain_paths: repository.company_brain_paths
    }

    lineage = put_in(request.lineage, [:github, :repo], repository.repo)
    %{request | routing: routing, lineage: lineage}
  end

  defp repo_from_url("https://github.com/" <> repo), do: String.trim_trailing(repo, ".git")
  defp repo_from_url("git@github.com:" <> repo), do: String.trim_trailing(repo, ".git")
  defp repo_from_url(_url), do: nil

  defp repo_slug(repo) when is_binary(repo), do: repo |> String.split("/") |> List.last()
  defp repo_slug(_repo), do: nil

  defp github_https_url(repo) when is_binary(repo) and repo != "", do: "https://github.com/#{repo}"
  defp github_https_url(_repo), do: nil

  defp new_run_id do
    "surf_run_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
