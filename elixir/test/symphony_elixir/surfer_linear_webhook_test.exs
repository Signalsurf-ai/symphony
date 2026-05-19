defmodule SymphonyElixir.SurferLinearWebhookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Surfer.Linear.{Session, Webhook}

  test "verifies Linear webhook signatures against raw body and timestamp" do
    body = ~s({"webhookTimestamp":#{System.system_time(:millisecond)},"type":"AgentSessionEvent"})
    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    assert :ok = Webhook.verify(body, signature, "secret")
    assert {:error, :invalid_signature} = Webhook.verify(body, "bad", "secret")
    assert {:error, :missing_signature} = Webhook.verify(body, nil, "secret")
  end

  test "verifies Linear webhook signatures against the next rotation secret" do
    body = ~s({"webhookTimestamp":#{System.system_time(:millisecond)},"type":"AgentSessionEvent"})
    next_signature = :crypto.mac(:hmac, :sha256, "next-secret", body) |> Base.encode16(case: :lower)

    log =
      capture_log([level: :debug], fn ->
        assert :ok = Webhook.verify(body, next_signature, ["current-secret", "next-secret"])
      end)

    assert log =~ "secret_slot=next"
    refute log =~ "current-secret"
    refute log =~ "next-secret"

    assert {:error, :invalid_signature} = Webhook.verify(body, "bad", ["current-secret", "next-secret"])
    assert {:error, :missing_secret} = Webhook.verify(body, next_signature, [])
  end

  test "rejects stale Linear webhook timestamps" do
    stale = System.system_time(:millisecond) - 120_000
    body = ~s({"webhookTimestamp":#{stale},"type":"AgentSessionEvent"})
    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    assert {:error, :stale_timestamp} = Webhook.verify(body, signature, "secret")
  end

  test "builds Linear agent activity mutations for lifecycle updates" do
    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql, query, variables})
      {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => true}}}}
    end

    assert :ok = Session.started("session-1", "surf_run_1", graphql_fun: graphql_fun)

    assert_receive {:graphql, query, variables}
    assert query =~ "agentActivityCreate"
    assert variables.sessionId == "session-1"
    assert variables.body =~ "surf_run_1"
    assert variables.type == "thought"

    assert :ok = Session.final_response("session-1", "Done", graphql_fun: graphql_fun)
    assert_receive {:graphql, _query, %{type: "response", body: "Done"}}

    assert :ok = Session.error("session-1", "Failed", graphql_fun: graphql_fun)
    assert_receive {:graphql, _query, %{type: "error", body: "Failed"}}
  end

  test "builds Linear agent session external URL updates" do
    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql, query, variables})
      {:ok, %{"data" => %{"agentSessionUpdate" => %{"success" => true}}}}
    end

    assert :ok =
             Session.update_external_urls(
               "session-1",
               [
                 %{label: "Surfer run", url: "http://127.0.0.1:4000/runs/surf_run_1"},
                 %{label: "GitHub PR", url: "https://github.com/acme/repo/pull/1"}
               ],
               graphql_fun: graphql_fun
             )

    assert_receive {:graphql, query, variables}
    assert query =~ "agentSessionUpdate"
    assert variables.sessionId == "session-1"

    assert variables.externalUrls == [
             %{label: "Surfer run", url: "http://127.0.0.1:4000/runs/surf_run_1"},
             %{label: "GitHub PR", url: "https://github.com/acme/repo/pull/1"}
           ]
  end
end
