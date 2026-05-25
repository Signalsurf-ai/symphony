defmodule SymphonyElixir.Surfer.Linear.Session do
  @moduledoc """
  Linear agent-session lifecycle writes.
  """

  alias SymphonyElixir.Linear.Client

  @activity_mutation """
  mutation SurferAgentActivity($sessionId: String!, $type: String!, $body: String!) {
    agentActivityCreate(input: {agentSessionId: $sessionId, type: $type, body: $body}) {
      success
    }
  }
  """

  @external_urls_mutation """
  mutation SurferAgentSessionExternalUrls($sessionId: String!, $externalUrls: [AgentSessionExternalUrlInput!]!) {
    agentSessionUpdate(id: $sessionId, input: {externalUrls: $externalUrls}) {
      success
    }
  }
  """

  @spec started(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def started(session_id, run_id, opts \\ []) do
    create_activity(session_id, "thought", started_body(run_id), opts)
  end

  @spec started_body(String.t()) :: String.t()
  def started_body(run_id) when is_binary(run_id), do: "Surfer started run #{run_id}."

  @spec final_response(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def final_response(session_id, body, opts \\ []) do
    create_activity(session_id, "response", body, opts)
  end

  @spec error(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def error(session_id, body, opts \\ []) do
    create_activity(session_id, "error", body, opts)
  end

  @spec update_external_urls(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def update_external_urls(session_id, external_urls, opts \\ [])
      when is_binary(session_id) and is_list(external_urls) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &Client.graphql/2)

    case graphql_fun.(@external_urls_mutation, %{
           sessionId: session_id,
           externalUrls: Enum.map(external_urls, &normalize_external_url/1)
         }) do
      {:ok, %{"data" => %{"agentSessionUpdate" => %{"success" => true}}}} -> :ok
      {:ok, _response} -> {:error, :agent_session_update_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_activity(session_id, type, body, opts) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &Client.graphql/2)

    case graphql_fun.(@activity_mutation, %{sessionId: session_id, type: type, body: body}) do
      {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => true}}}} -> :ok
      {:ok, _response} -> {:error, :agent_activity_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_external_url(%{label: label, url: url}), do: %{label: label, url: url}
  defp normalize_external_url(%{"label" => label, "url" => url}), do: %{label: label, url: url}
end
