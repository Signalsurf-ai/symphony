defmodule SymphonyElixir.SurferRunRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.Discord.Interaction
  alias SymphonyElixir.Surfer.RunRequest

  test "normalizes Linear AgentSessionEvent payloads into durable coding tasks" do
    payload = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "organizationId" => "org-1",
      "webhookId" => "webhook-1",
      "webhookTimestamp" => 1_700_000_000_000,
      "actor" => %{"id" => "user-1"},
      "agentSession" => %{
        "id" => "session-1",
        "promptContext" => "<issue identifier=\"ENG-1\">Fix it</issue>",
        "issue" => %{
          "id" => "issue-1",
          "identifier" => "ENG-1",
          "title" => "Fix bug",
          "description" => "Broken",
          "priority" => 2,
          "url" => "https://linear.app/acme/issue/ENG-1/fix-bug",
          "branchName" => "eng-1-fix-bug",
          "state" => %{"name" => "Todo"},
          "labels" => %{"nodes" => [%{"name" => "bug"}]}
        },
        "comment" => %{"id" => "comment-1", "body" => "Please implement"}
      }
    }

    assert {:ok, request} = RunRequest.from_linear_agent_session_event(payload)

    assert request.run_id =~ "surf_run_"
    assert request.source.platform == :linear
    assert request.source.trigger_type == :delegation
    assert request.source.actor_id == "user-1"
    assert request.source.organization_id == "org-1"
    assert request.source.received_at == "2023-11-14T22:13:20.000Z"
    assert request.request.mode == :durable_task
    assert request.request.trigger_type == :delegation
    assert request.request.prompt_context == "<issue identifier=\"ENG-1\">Fix it</issue>"
    assert request.constraints == %{read_only: false, require_linear_issue: true, allow_pr_creation: true}
    assert request.lineage.linear.issue_id == "issue-1"
    assert request.lineage.linear.issue_identifier == "ENG-1"
    assert request.lineage.linear.agent_session_id == "session-1"
    assert request.lineage.linear.comment_id == "comment-1"
    assert request.context.prompt_context == "<issue identifier=\"ENG-1\">Fix it</issue>"
    assert request.issue.title == "Fix bug"
    assert request.issue.labels == ["bug"]

    context = RunRequest.surfer_context(request)
    assert context.trigger_type == "delegation"
    assert context.organization_id == "org-1"
    assert context.source.received_at == "2023-11-14T22:13:20.000Z"
  end

  test "normalizes Linear mentions as scoped code questions unless implementation is requested" do
    payload = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "organizationId" => "org-1",
      "webhookId" => "webhook-question",
      "agentSession" => %{
        "id" => "session-question",
        "promptContext" => """
        <issue identifier="ENG-2">Improve routing</issue>
        <primary-directive-thread>Where is routing handled?</primary-directive-thread>
        """,
        "issue" => %{
          "id" => "issue-2",
          "identifier" => "ENG-2",
          "title" => "Improve routing",
          "state" => %{"name" => "Todo"}
        },
        "comment" => %{"id" => "comment-question", "body" => "Where is routing handled?"}
      }
    }

    assert {:ok, request} = RunRequest.from_linear_agent_session_event(payload)

    assert request.source.trigger_type == :mention
    assert request.request.mode == :code_question
    assert request.request.trigger_type == :mention
    assert request.request.body == "Where is routing handled?"
    assert request.constraints == %{read_only: true, require_linear_issue: false, allow_pr_creation: false}
    assert request.source.natural_event_key == "linear:session-question:created:comment-question:code_question"
  end

  test "normalizes Linear prompted help as scoped assistance and prompted implementation as durable work" do
    prompted_help = %{
      "type" => "AgentSessionEvent",
      "action" => "prompted",
      "agentSession" => %{
        "id" => "session-prompted",
        "issue" => %{"id" => "issue-3", "identifier" => "ENG-3", "title" => "Routing", "state" => %{"name" => "Todo"}},
        "agentActivity" => %{"id" => "activity-help", "body" => "Can you explain the routing flow?"}
      }
    }

    assert {:ok, help_request} = RunRequest.from_linear_agent_session_event(prompted_help)
    assert help_request.source.trigger_type == :mention
    assert help_request.request.mode == :code_question
    assert help_request.request.body == "Can you explain the routing flow?"
    assert RunRequest.idempotency_key(help_request) == "linear:session-prompted:prompted:activity-help:code_question"

    prompted_work =
      put_in(prompted_help, ["agentSession", "agentActivity"], %{
        "id" => "activity-work",
        "body" => "Please implement the routing fix."
      })

    assert {:ok, work_request} = RunRequest.from_linear_agent_session_event(prompted_work)
    assert work_request.source.trigger_type == :delegation
    assert work_request.request.mode == :durable_task
    assert work_request.request.body == "Please implement the routing fix."
    assert RunRequest.idempotency_key(work_request) == "linear:session-prompted:prompted:activity-work:durable_task"
  end

  test "keeps advisory Linear phrasing read-only even when it mentions implementation verbs" do
    advisory = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "agentSession" => %{
        "id" => "session-advisory",
        "issue" => %{"id" => "issue-advisory", "identifier" => "ENG-4", "title" => "Routing", "state" => %{"name" => "Todo"}},
        "comment" => %{"id" => "comment-advisory", "body" => "How should we fix the routing flow?"}
      }
    }

    assert {:ok, request} = RunRequest.from_linear_agent_session_event(advisory)

    assert request.source.trigger_type == :mention
    assert request.request.mode == :code_question
    assert request.request.body == "How should we fix the routing flow?"
    assert RunRequest.idempotency_key(request) == "linear:session-advisory:created:comment-advisory:code_question"
  end

  test "surfer context exposes a bounded redacted platform prompt context" do
    prompt_context =
      """
      <issue identifier="ENG-1">Fix it</issue>
      Authorization: Bearer linear-oauth-secret
      DISCORD_BOT_TOKEN=discord-bot-secret
      access_token: "quoted-oauth-secret"
      webhook_secret='quoted-webhook-secret'
      """

    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-1",
                 "promptContext" => prompt_context,
                 "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
               }
             })

    context = RunRequest.surfer_context(request)

    assert context.prompt_context =~ "<issue identifier=\"ENG-1\">Fix it</issue>"
    assert context.prompt_context =~ "Authorization: Bearer [REDACTED]"
    assert context.prompt_context =~ "DISCORD_BOT_TOKEN=[REDACTED]"
    assert context.prompt_context =~ ~s(access_token: "[REDACTED]")
    assert context.prompt_context =~ "webhook_secret='[REDACTED]'"
    refute context.prompt_context =~ "linear-oauth-secret"
    refute context.prompt_context =~ "discord-bot-secret"
    refute context.prompt_context =~ "quoted-oauth-secret"
    refute context.prompt_context =~ "quoted-webhook-secret"
  end

  test "normalizes Discord code questions and issue creation requests" do
    code_question = %{
      "id" => "message-1",
      "guild_id" => "guild-1",
      "channel_id" => "channel-1",
      "thread_id" => "thread-1",
      "timestamp" => "2026-05-19T10:30:00.000Z",
      "author" => %{"id" => "user-1"},
      "content" => "surfer question: where is routing handled?"
    }

    assert {:ok, question} = RunRequest.from_discord_message(code_question)
    assert question.source.platform == :discord
    assert question.source.natural_event_key == "discord_message:guild-1:channel-1:message-1:code_question"
    assert question.source.received_at == "2026-05-19T10:30:00.000Z"
    assert question.request.mode == :code_question
    assert question.request.trigger_type == :message
    assert question.request.prompt_context == "surfer question: where is routing handled?"
    assert question.constraints == %{read_only: true, require_linear_issue: false, allow_pr_creation: false}
    assert question.lineage.discord.message_id == "message-1"

    issue_request = %{code_question | "id" => "message-2", "content" => "surfer create issue: fix routing"}

    assert {:ok, issue_create} = RunRequest.from_discord_message(issue_request)
    assert issue_create.request.mode == :issue_create
    assert issue_create.constraints == %{read_only: false, require_linear_issue: false, allow_pr_creation: false}
  end

  test "uses natural idempotency keys instead of webhook delivery metadata" do
    created_payload = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "webhookId" => "delivery-1",
      "agentSession" => %{
        "id" => "session-1",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}},
        "comment" => %{"id" => "comment-1"}
      }
    }

    assert {:ok, created} = RunRequest.from_linear_agent_session_event(created_payload)
    assert RunRequest.idempotency_key(created) == "linear:session-1:created:comment-1:durable_task"

    redelivery_payload = %{created_payload | "webhookId" => "delivery-2"}
    assert {:ok, redelivery} = RunRequest.from_linear_agent_session_event(redelivery_payload)
    assert RunRequest.idempotency_key(redelivery) == RunRequest.idempotency_key(created)

    prompted_payload =
      created_payload
      |> Map.put("action", "prompted")
      |> put_in(["agentSession", "agentActivity"], %{"id" => "activity-1", "body" => "Please implement"})

    assert {:ok, prompted} = RunRequest.from_linear_agent_session_event(prompted_payload)
    assert RunRequest.idempotency_key(prompted) == "linear:session-1:prompted:activity-1:durable_task"
  end

  test "rejects unsupported Linear AgentSessionEvent actions" do
    payload = %{
      "type" => "AgentSessionEvent",
      "action" => "archived",
      "webhookId" => "delivery-unsupported",
      "agentSession" => %{
        "id" => "session-unsupported",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, {:unsupported_linear_agent_action, "archived"}} =
             RunRequest.from_linear_agent_session_event(payload)
  end

  test "rejects Linear AgentSessionEvent payloads without an action" do
    payload = %{
      "type" => "AgentSessionEvent",
      "webhookId" => "delivery-missing-action",
      "agentSession" => %{
        "id" => "session-missing-action",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, :missing_linear_agent_action} =
             RunRequest.from_linear_agent_session_event(payload)
  end

  test "rejects explicit non-AgentSessionEvent Linear payload types" do
    payload = %{
      "type" => "Issue",
      "action" => "created",
      "webhookId" => "delivery-unsupported-type",
      "agentSession" => %{
        "id" => "session-unsupported-type",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, {:unsupported_linear_event_type, "Issue"}} =
             RunRequest.from_linear_agent_session_event(payload)
  end

  test "rejects Linear payloads without an AgentSessionEvent type" do
    payload = %{
      "action" => "created",
      "webhookId" => "delivery-missing-type",
      "agentSession" => %{
        "id" => "session-missing-type",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, :missing_linear_event_type} =
             RunRequest.from_linear_agent_session_event(payload)
  end

  test "rejects prompted Linear AgentSessionEvent payloads without prompt text" do
    payload = %{
      "type" => "AgentSessionEvent",
      "action" => "prompted",
      "webhookId" => "delivery-blank-prompted",
      "agentSession" => %{
        "id" => "session-blank-prompted",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}},
        "agentActivity" => %{"id" => "activity-blank", "body" => "   "}
      }
    }

    assert {:error, :missing_linear_prompted_directive} =
             RunRequest.from_linear_agent_session_event(payload)
  end

  test "rejects Linear payloads missing required natural-key components" do
    missing_session_id = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "agentSession" => %{
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, :missing_linear_agent_session_id} =
             RunRequest.from_linear_agent_session_event(missing_session_id)

    prompted_without_activity = %{
      "type" => "AgentSessionEvent",
      "action" => "prompted",
      "agentSession" => %{
        "id" => "session-1",
        "issue" => %{"id" => "issue-1", "identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, :missing_linear_agent_activity_id} =
             RunRequest.from_linear_agent_session_event(prompted_without_activity)

    created_without_subject = %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "agentSession" => %{
        "id" => "session-1",
        "issue" => %{"identifier" => "ENG-1", "title" => "Fix", "state" => %{"name" => "Todo"}}
      }
    }

    assert {:error, :missing_linear_issue_or_comment_id} =
             RunRequest.from_linear_agent_session_event(created_without_subject)
  end

  test "deduplicates Discord events by interaction or message without retaining bearer tokens" do
    interaction = %{
      "id" => "interaction-1",
      "application_id" => "app-1",
      "token" => "secret-token",
      "type" => 2,
      "guild_id" => "guild-1",
      "channel_id" => "channel-1",
      "member" => %{"user" => %{"id" => "user-1"}},
      "data" => %{
        "name" => "surfer",
        "options" => [
          %{"name" => "prompt", "type" => 3, "value" => "where is routing handled?"}
        ]
      }
    }

    assert {:ok, request} = Interaction.to_run_request(interaction)
    assert request.source.natural_event_key == "discord_interaction:interaction-1:code_question"
    assert request.request.trigger_type == :slash_command
    assert RunRequest.idempotency_key(request) == "discord_interaction:interaction-1:code_question"
    refute Map.has_key?(request.lineage.discord, :interaction_token)
    refute inspect(RunRequest.surfer_context(request)) =~ "secret-token"

    assert {:ok, message} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert RunRequest.idempotency_key(message) == "discord_message:guild-1:channel-1:message-1:code_question"
  end

  test "rejects Discord payloads missing required natural-key components" do
    assert {:error, :missing_discord_message_id} =
             RunRequest.from_discord_message(%{
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:error, :missing_discord_guild_id} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    assert {:error, :missing_discord_channel_id} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "content" => "surfer question"
             })

    interaction = %{
      "application_id" => "app-1",
      "type" => 2,
      "guild_id" => "guild-1",
      "channel_id" => "channel-1",
      "member" => %{"user" => %{"id" => "user-1"}},
      "data" => %{
        "name" => "surfer",
        "options" => [
          %{"name" => "prompt", "type" => 3, "value" => "where is routing handled?"}
        ]
      }
    }

    assert {:error, :missing_discord_interaction_id} = Interaction.to_run_request(interaction)
  end

  test "routes requests deterministically and fails visibly on ambiguous repositories" do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    repositories = [
      %{name: "api", url: "https://github.com/acme/api", workflow: "./WORKFLOW.md"},
      %{name: "web", url: "https://github.com/acme/web", workflow: "./WORKFLOW.md"}
    ]

    assert {:error, {:ambiguous_repository, ["api", "web"]}} =
             RunRequest.route(request, repositories)

    assert {:ok, routed} =
             RunRequest.route(%{request | routing: %{repository: "api"}}, repositories)

    assert routed.routing.repository == "api"
    assert routed.routing.workflow_path == "./WORKFLOW.md"
  end

  test "routes Linear requests by configured team id and exposes PRD routing metadata" do
    assert {:ok, request} =
             RunRequest.from_linear_agent_session_event(%{
               "type" => "AgentSessionEvent",
               "action" => "created",
               "agentSession" => %{
                 "id" => "session-1",
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "ENG-1",
                   "title" => "Fix",
                   "team" => %{"id" => "team-web"},
                   "state" => %{"name" => "Todo"}
                 }
               }
             })

    repositories = [
      %{key: "api", repo: "acme/api", checkout_path: "/srv/surfer/repos/api", linear_team_ids: ["team-api"]},
      %{
        key: "web",
        repo: "acme/web",
        checkout_path: "/srv/surfer/repos/web",
        workflow: "./WEB_WORKFLOW.md",
        default_branch: "main",
        linear_team_ids: ["team-web"],
        company_brain_paths: ["meetings/"]
      }
    ]

    assert {:ok, routed} = RunRequest.route(request, repositories)

    assert routed.routing.repository_key == "web"
    assert routed.routing.repository_full_name == "acme/web"
    assert routed.routing.checkout_path == "/srv/surfer/repos/web"
    assert routed.routing.workflow_path == "./WEB_WORKFLOW.md"
    assert routed.routing.branch_hint == "main"
    assert routed.routing.confidence == :source_hint
    assert routed.routing.reason =~ "Linear team id"
    assert routed.routing.company_brain_paths == ["meetings/"]

    context = RunRequest.surfer_context(routed)
    assert context.routing.repository_key == "web"
    assert context.routing.repository_full_name == "acme/web"
  end

  test "routes Discord requests by configured channel id" do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-web",
               "content" => "surfer implement routing"
             })

    repositories = [
      %{key: "api", repo: "acme/api", discord_channel_ids: ["channel-api"]},
      %{key: "web", repo: "acme/web", discord_channel_ids: ["channel-web"]}
    ]

    assert {:ok, routed} = RunRequest.route(request, repositories)
    assert routed.routing.repository_key == "web"
    assert routed.routing.reason =~ "Discord channel id"
  end

  test "explicit repository routing accepts either repository_key or legacy repository name" do
    assert {:ok, request} =
             RunRequest.from_discord_message(%{
               "id" => "message-1",
               "guild_id" => "guild-1",
               "channel_id" => "channel-1",
               "content" => "surfer question"
             })

    repositories = [
      %{key: "api", repo: "acme/api"},
      %{key: "web", repo: "acme/web"}
    ]

    assert {:ok, routed_by_key} =
             RunRequest.route(%{request | routing: %{repository_key: "web"}}, repositories)

    assert routed_by_key.routing.repository_key == "web"
    assert routed_by_key.routing.confidence == :explicit

    assert {:ok, routed_by_legacy_name} =
             RunRequest.route(%{request | routing: %{repository: "api"}}, repositories)

    assert routed_by_legacy_name.routing.repository_key == "api"
  end
end
