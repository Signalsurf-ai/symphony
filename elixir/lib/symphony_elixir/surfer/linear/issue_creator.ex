defmodule SymphonyElixir.Surfer.Linear.IssueCreator do
  @moduledoc """
  Creates Linear issues for Discord-originated durable requests.
  """

  alias SymphonyElixir.Linear.Client

  @mutation """
  mutation SurferIssueCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        url
      }
    }
  }
  """

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &Client.graphql/2)

    with {:ok, input} <- issue_input(attrs, opts),
         {:ok, response} <- graphql_fun.(@mutation, %{input: input}) do
      normalize_response(response)
    end
  end

  defp issue_input(attrs, opts) do
    case nonblank_string(Keyword.get(opts, :team_id)) do
      {:ok, team_id} ->
        input =
          %{
            teamId: team_id,
            title: Map.get(attrs, :title) || Map.get(attrs, "title"),
            description: Map.get(attrs, :description) || Map.get(attrs, "description")
          }
          |> put_optional(:projectId, normalized_optional_id(Keyword.get(opts, :project_id)))
          |> put_optional(:stateId, normalized_optional_id(Keyword.get(opts, :state_id)))

        {:ok, input}

      :error ->
        {:error, :missing_linear_team_id}
    end
  end

  defp normalized_optional_id(value) do
    case nonblank_string(value) do
      {:ok, string} -> string
      :error -> nil
    end
  end

  defp nonblank_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: :error, else: {:ok, value}
  end

  defp nonblank_string(_value), do: :error

  defp normalize_response(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}})
       when is_map(issue) do
    {:ok,
     %{
       id: Map.get(issue, "id"),
       identifier: Map.get(issue, "identifier"),
       title: Map.get(issue, "title"),
       url: Map.get(issue, "url")
     }}
  end

  defp normalize_response(_response), do: {:error, :issue_create_failed}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
