defmodule SymphonyElixir.SurferPlatformsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.{Discord, GitHub, Linear}

  setup {Req.Test, :verify_on_exit!}

  test "Discord webhook verifier accepts official interaction signatures" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    timestamp = Integer.to_string(System.system_time(:second))
    body = ~s({"type":1})

    signature =
      :crypto.sign(:eddsa, :none, timestamp <> body, [private_key, :ed25519])
      |> Base.encode16(case: :lower)

    assert :ok =
             Discord.Webhook.verify(
               body,
               signature,
               timestamp,
               Base.encode16(public_key, case: :lower)
             )

    assert {:error, :invalid_signature} =
             Discord.Webhook.verify(
               body,
               String.duplicate("0", 128),
               timestamp,
               Base.encode16(public_key, case: :lower)
             )
  end

  test "Discord webhook verifier accepts the next rotation public key" do
    {current_public_key, _current_private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {next_public_key, next_private_key} = :crypto.generate_key(:eddsa, :ed25519)
    timestamp = Integer.to_string(System.system_time(:second))
    body = ~s({"type":1})
    current_public_key_hex = Base.encode16(current_public_key, case: :lower)
    next_public_key_hex = Base.encode16(next_public_key, case: :lower)

    signature =
      :crypto.sign(:eddsa, :none, timestamp <> body, [next_private_key, :ed25519])
      |> Base.encode16(case: :lower)

    log =
      capture_log([level: :debug], fn ->
        assert :ok =
                 Discord.Webhook.verify(
                   body,
                   signature,
                   timestamp,
                   [
                     current_public_key_hex,
                     next_public_key_hex
                   ]
                 )
      end)

    assert log =~ "public_key_slot=next"
    refute log =~ current_public_key_hex
    refute log =~ next_public_key_hex
  end

  test "Discord interactions normalize slash commands into message-shaped Surfer requests" do
    interaction = %{
      "id" => "interaction-1",
      "application_id" => "app-1",
      "token" => "token-1",
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

    assert {:ok, request} =
             Discord.Interaction.to_run_request(interaction,
               allowed_guilds: ["guild-1"],
               allowed_channels: ["channel-1"]
             )

    assert request.source.platform == :discord
    assert request.source.trigger_type == :slash_command
    assert request.source.raw_event_id == "interaction-1"
    assert request.request.mode == :code_question
    assert request.request.body == "where is routing handled?"
    assert request.lineage.discord.interaction_id == "interaction-1"
    refute Map.has_key?(request.lineage.discord, :interaction_token)
    assert request.lineage.discord.application_id == "app-1"
  end

  test "Discord interactions parse Surfer subcommand grammar" do
    base = %{
      "id" => "interaction-1",
      "application_id" => "app-1",
      "type" => 2,
      "guild_id" => "guild-1",
      "channel_id" => "channel-1",
      "member" => %{"user" => %{"id" => "user-1"}},
      "data" => %{"name" => "surfer"}
    }

    ask = put_in(base, ["data", "options"], [%{"name" => "ask", "type" => 1, "options" => [%{"name" => "prompt", "value" => "Where is routing?"}]}])
    issue = put_in(base, ["id"], "interaction-2") |> put_in(["data", "options"], [%{"name" => "issue", "type" => 1, "options" => [%{"name" => "prompt", "value" => "Fix routing"}]}])
    run = put_in(base, ["id"], "interaction-3") |> put_in(["data", "options"], [%{"name" => "run", "type" => 1, "options" => [%{"name" => "prompt", "value" => "Implement routing"}]}])
    cancel = put_in(base, ["id"], "interaction-4") |> put_in(["data", "options"], [%{"name" => "cancel", "type" => 1, "options" => [%{"name" => "run_id", "value" => "surf_run_1"}]}])

    assert {:ok, ask_request} = Discord.Interaction.to_run_request(ask)
    assert ask_request.request.mode == :code_question
    assert ask_request.request.body == "Where is routing?"

    assert {:ok, issue_request} = Discord.Interaction.to_run_request(issue)
    assert issue_request.request.mode == :issue_create
    assert issue_request.request.body == "Fix routing"

    assert {:ok, run_request} = Discord.Interaction.to_run_request(run)
    assert run_request.request.mode == :durable_task
    assert run_request.request.body == "Implement routing"

    assert {:ok, cancel_request} = Discord.Interaction.to_run_request(cancel)
    assert cancel_request.request.mode == :lifecycle_control
    assert cancel_request.request.action == :cancel
    assert cancel_request.request.run_id == "surf_run_1"
  end

  test "Discord command registration payload matches supported Surfer grammar" do
    command = Discord.Commands.application_command()

    assert %{name: "surfer", type: 1, options: options} = command
    assert Enum.map(options, & &1.name) == ["ask", "issue", "run", "cancel", "retry"]

    prompt_commands = Enum.filter(options, &(&1.name in ["ask", "issue", "run"]))
    lifecycle_commands = Enum.filter(options, &(&1.name in ["cancel", "retry"]))

    assert Enum.all?(prompt_commands, fn subcommand ->
             assert [%{name: "prompt", type: 3, required: true}] = subcommand.options
           end)

    assert Enum.all?(lifecycle_commands, fn subcommand ->
             assert [%{name: "run_id", type: 3, required: true}] = subcommand.options
           end)
  end

  test "Discord command registration upserts Surfer command in the configured guild" do
    parent = self()

    request_fun = fn url, headers, body ->
      send(parent, {:discord_command_registration, url, headers, body})
      {:ok, %{"id" => "command-1", "name" => body.name}}
    end

    assert {:ok, %{"id" => "command-1", "name" => "surfer"}} =
             Discord.Commands.register_guild_command(
               %{
                 application_id: "app-1",
                 guild_id: "guild-1",
                 bot_token: "bot-secret"
               },
               request_fun: request_fun
             )

    assert_receive {:discord_command_registration, url, headers, body}
    assert url == "https://discord.com/api/v10/applications/app-1/guilds/guild-1/commands"
    assert {"authorization", "Bot bot-secret"} in headers
    assert {"content-type", "application/json"} in headers
    assert body == Discord.Commands.application_command()
    refute inspect(body) =~ "bot-secret"

    assert {:error, :missing_discord_application_id} =
             Discord.Commands.register_guild_command(%{guild_id: "guild-1", bot_token: "bot-secret"})

    assert {:error, :missing_discord_bot_token} =
             Discord.Commands.register_guild_command(%{application_id: "app-1", guild_id: "guild-1"})

    assert {:error, :missing_discord_guild_id} =
             Discord.Commands.register_guild_command(%{application_id: "app-1", bot_token: "bot-secret"})

    assert {:error, :invalid_discord_command_registration} = Discord.Commands.register_guild_command(nil)
  end

  test "Discord command registration default request handles API and transport results" do
    original_req_options = Req.default_options()
    on_exit(fn -> Req.default_options(original_req_options) end)

    success_stub = {:discord_commands, self(), :success}

    Req.Test.expect(success_stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v10/applications/app-1/guilds/guild-1/commands"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot bot-secret"]
      assert Jason.decode!(Req.Test.raw_body(conn))["name"] == "surfer"

      Req.Test.json(conn, %{"id" => "command-1", "name" => "surfer"})
    end)

    Req.default_options(plug: {Req.Test, success_stub}, retry: false)

    assert {:ok, %{"id" => "command-1", "name" => "surfer"}} =
             Discord.Commands.register_guild_command(%{
               "application_id" => "app-1",
               "guild_id" => "guild-1",
               "bot_token" => "bot-secret"
             })

    api_error_stub = {:discord_commands, self(), :api_error}

    Req.Test.expect(api_error_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"message" => "unauthorized"})
    end)

    Req.default_options(plug: {Req.Test, api_error_stub}, retry: false)

    assert {:error, {:discord_status, 401, %{"message" => "unauthorized"}}} =
             Discord.Commands.register_guild_command(%{
               application_id: "app-1",
               guild_id: "guild-1",
               bot_token: "bot-secret"
             })

    transport_error_stub = {:discord_commands, self(), :transport_error}

    Req.Test.expect(transport_error_stub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    Req.default_options(plug: {Req.Test, transport_error_stub}, retry: false)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Discord.Commands.register_guild_command(%{
               application_id: "app-1",
               guild_id: "guild-1",
               bot_token: "bot-secret"
             })
  end

  test "Discord ingress rejects unconfigured guilds" do
    event = %{
      "id" => "message-1",
      "guild_id" => "guild-2",
      "channel_id" => "channel-1",
      "content" => "surfer question"
    }

    assert {:error, {:unauthorized_guild, "guild-2"}} =
             Discord.Ingress.normalize_message(event, allowed_guilds: ["guild-1"])
  end

  test "Discord issue creation calls Linear and posts a link back" do
    parent = self()

    create_issue_fun = fn attrs ->
      send(parent, {:create_issue, attrs})
      {:ok, %{id: "issue-1", identifier: "ENG-1", url: "https://linear.app/acme/issue/ENG-1/test"}}
    end

    post_message_fun = fn channel_id, body ->
      send(parent, {:post_message, channel_id, body})
      :ok
    end

    assert {:ok, issue} =
             Discord.IssueBridge.create_linear_issue(
               %{
                 "id" => "message-1",
                 "guild_id" => "guild-1",
                 "channel_id" => "channel-1",
                 "content" => "surfer create issue: fix routing"
               },
               create_issue_fun: create_issue_fun,
               post_message_fun: post_message_fun
             )

    assert issue.identifier == "ENG-1"
    assert_receive {:create_issue, attrs}
    assert attrs.title == "fix routing"
    assert attrs.description =~ "Discord message"
    assert_receive {:post_message, "channel-1", body}
    assert body =~ "ENG-1"
  end

  test "Company Brain retrieval is scoped to configured repo and paths" do
    fetch_fun = fn repo, paths ->
      assert repo == "acme/company-brain"
      assert paths == ["meetings/", "research/"]

      {:ok,
       [
         %{path: "meetings/2026-05-01.md", summary: "Decision notes", url: "https://github.com/acme/company-brain/blob/main/meetings/2026-05-01.md"},
         %{path: "policies/secrets.md", summary: "must not leak", url: "https://github.com/acme/company-brain/blob/main/policies/secrets.md"}
       ]}
    end

    assert {:ok, refs} =
             GitHub.CompanyBrain.retrieve(%{
               company_brain_repo: "acme/company-brain",
               company_brain_paths: ["meetings/", "research/"],
               fetch_fun: fetch_fun
             })

    assert [
             %{
               path: "meetings/2026-05-01.md",
               role: :background_context,
               authoritative?: false
             }
           ] = refs
  end

  test "Company Brain retrieval returns provenance only and bounds summaries" do
    long_summary = String.duplicate("a", 520)
    secret_summary = "Routing note Authorization: Bearer brain-secret api_key=brain-api-key"

    fetch_fun = fn _repo, _paths ->
      {:ok,
       [
         %{
           path: "meetings/2026-05-01.md",
           url: "https://github.com/acme/company-brain/blob/main/meetings/2026-05-01.md",
           summary: long_summary,
           content: "raw meeting transcript",
           access_token: "github-token"
         },
         %{
           path: "meetings/2026-05-02.md",
           url: "https://github.com/acme/company-brain/blob/main/meetings/2026-05-02.md",
           summary: secret_summary
         }
       ]}
    end

    assert {:ok, [ref, secret_ref]} =
             GitHub.CompanyBrain.retrieve(%{
               company_brain_repo: "acme/company-brain",
               company_brain_paths: ["meetings/"],
               fetch_fun: fetch_fun
             })

    assert ref.path == "meetings/2026-05-01.md"
    assert ref.url == "https://github.com/acme/company-brain/blob/main/meetings/2026-05-01.md"
    assert ref.summary == String.duplicate("a", 500) <> "..."
    assert ref.authority == :background
    assert ref.role == :background_context
    refute Map.has_key?(ref, :content)
    refute Map.has_key?(ref, :access_token)

    assert secret_ref.summary =~ "Authorization: Bearer [REDACTED]"
    assert secret_ref.summary =~ "api_key=[REDACTED]"
    refute secret_ref.summary =~ "brain-secret"
    refute secret_ref.summary =~ "brain-api-key"
  end

  test "GitHub pull request helper updates an existing head branch instead of creating duplicate PRs" do
    parent = self()

    api_fun = fn method, path, body, token ->
      send(parent, {:github_api, method, path, body, token})

      case {method, path} do
        {:get, "/repos/acme/web/pulls?state=open&head=acme%3Asurfer%2Ffix-routing"} ->
          {:ok, [%{"number" => 42, "html_url" => "https://github.com/acme/web/pull/42"}]}

        {:patch, "/repos/acme/web/pulls/42"} ->
          {:ok, %{"number" => 42, "html_url" => "https://github.com/acme/web/pull/42", "title" => body.title, "state" => "open"}}
      end
    end

    assert {:ok, pr} =
             GitHub.PullRequest.create_or_update(
               %{
                 repo: "acme/web",
                 head: "surfer/fix-routing",
                 base: "main",
                 title: "Fix routing",
                 body: "Surfer run surf_run_1",
                 token: "github-token"
               },
               api_fun: api_fun
             )

    assert pr.number == 42
    assert_receive {:github_api, :get, _path, nil, "github-token"}
    assert_receive {:github_api, :patch, "/repos/acme/web/pulls/42", patch_body, "github-token"}
    assert patch_body.title == "Fix routing"
  end

  test "GitHub pull request helper creates a PR when no open PR exists for the head branch" do
    api_fun = fn
      :get, "/repos/acme/web/pulls?state=open&head=acme%3Asurfer%2Fnew", nil, "github-token" ->
        {:ok, []}

      :post, "/repos/acme/web/pulls", body, "github-token" ->
        assert body.head == "surfer/new"
        assert body.base == "main"
        {:ok, %{"number" => 7, "html_url" => "https://github.com/acme/web/pull/7", "title" => body.title, "state" => "open"}}
    end

    assert {:ok, %{number: 7, url: "https://github.com/acme/web/pull/7"}} =
             GitHub.PullRequest.create_or_update(
               %{
                 repo: "acme/web",
                 head: "surfer/new",
                 title: "Implement Surfer",
                 body: "Surfer run surf_run_2",
                 token: "github-token"
               },
               api_fun: api_fun
             )
  end

  test "GitHub pull request helper reads PR review context with provenance" do
    parent = self()

    api_fun = fn method, path, body, token ->
      send(parent, {:github_api, method, path, body, token})

      case {method, path} do
        {:get, "/repos/acme/web/pulls/42"} ->
          {:ok,
           %{
             "number" => 42,
             "html_url" => "https://github.com/acme/web/pull/42",
             "title" => "Fix routing",
             "state" => "open",
             "head" => %{"ref" => "surfer/fix-routing"},
             "base" => %{"ref" => "main"}
           }}

        {:get, "/repos/acme/web/pulls/42/reviews"} ->
          {:ok,
           [
             %{
               "id" => 100,
               "state" => "CHANGES_REQUESTED",
               "body" => "Needs test coverage. Authorization: Bearer review-secret",
               "user" => %{"login" => "reviewer"},
               "submitted_at" => "2026-05-19T01:02:03Z",
               "html_url" => "https://github.com/acme/web/pull/42#pullrequestreview-100"
             }
           ]}

        {:get, "/repos/acme/web/pulls/42/comments"} ->
          {:ok,
           [
             %{
               "id" => 200,
               "path" => "lib/router.ex",
               "line" => 12,
               "body" => "Handle ambiguity here. api_key=comment-secret",
               "user" => %{"login" => "reviewer"},
               "html_url" => "https://github.com/acme/web/pull/42#discussion_r200"
             }
           ]}

        {:get, "/repos/acme/web/pulls/42/files"} ->
          {:ok, [%{"filename" => "lib/router.ex", "status" => "modified", "changes" => 8}]}
      end
    end

    assert {:ok, context} =
             GitHub.PullRequest.review_context(
               %{repo: "acme/web", number: 42, token: "github-token"},
               api_fun: api_fun
             )

    assert context.pull_request.number == 42
    assert context.pull_request.url == "https://github.com/acme/web/pull/42"
    assert context.pull_request.head_ref == "surfer/fix-routing"

    assert context.reviews == [
             %{
               id: 100,
               state: "CHANGES_REQUESTED",
               author: "reviewer",
               body: "Needs test coverage. Authorization: Bearer [REDACTED]",
               submitted_at: "2026-05-19T01:02:03Z",
               url: "https://github.com/acme/web/pull/42#pullrequestreview-100"
             }
           ]

    assert context.comments == [
             %{
               id: 200,
               path: "lib/router.ex",
               line: 12,
               author: "reviewer",
               body: "Handle ambiguity here. api_key=[REDACTED]",
               url: "https://github.com/acme/web/pull/42#discussion_r200"
             }
           ]

    refute inspect(context) =~ "review-secret"
    refute inspect(context) =~ "comment-secret"
    assert context.files == [%{filename: "lib/router.ex", status: "modified", changes: 8}]
    assert context.provenance == %{repo: "acme/web", pr_number: 42, source_url: "https://github.com/acme/web/pull/42", authority: :github_pr_context}

    assert_receive {:github_api, :get, "/repos/acme/web/pulls/42", nil, "github-token"}
    assert_receive {:github_api, :get, "/repos/acme/web/pulls/42/reviews", nil, "github-token"}
    assert_receive {:github_api, :get, "/repos/acme/web/pulls/42/comments", nil, "github-token"}
    assert_receive {:github_api, :get, "/repos/acme/web/pulls/42/files", nil, "github-token"}
  end

  test "Linear issue creation uses the configured team and optional project" do
    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql, query, variables})

      {:ok,
       %{
         "data" => %{
           "issueCreate" => %{
             "success" => true,
             "issue" => %{
               "id" => "issue-1",
               "identifier" => "SURF-1",
               "title" => "Fix routing",
               "url" => "https://linear.app/acme/issue/SURF-1/fix-routing"
             }
           }
         }
       }}
    end

    assert {:ok, issue} =
             Linear.IssueCreator.create(
               %{title: "Fix routing", description: "From Discord"},
               team_id: "team-1",
               project_id: "project-1",
               graphql_fun: graphql_fun
             )

    assert issue.identifier == "SURF-1"
    assert_receive {:graphql, query, variables}
    assert query =~ "issueCreate"
    assert variables.input.teamId == "team-1"
    assert variables.input.projectId == "project-1"
    assert variables.input.title == "Fix routing"
  end
end
