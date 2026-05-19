defmodule SymphonyElixir.Surfer.Discord.IssueBridge do
  @moduledoc """
  Creates Linear issues from Discord-originated durable work requests.
  """

  @spec create_linear_issue(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_linear_issue(message, opts \\ []) when is_map(message) do
    create_issue_fun = Keyword.fetch!(opts, :create_issue_fun)
    post_message_fun = Keyword.get(opts, :post_message_fun, fn _channel_id, _body -> :ok end)
    title = title_from_message(Map.get(message, "content", ""))

    attrs = %{
      title: title,
      description: description_from_message(message)
    }

    with {:ok, issue} <- create_issue_fun.(attrs),
         :ok <- post_message_fun.(Map.get(message, "channel_id"), issue_message(issue)) do
      {:ok, issue}
    end
  end

  defp title_from_message(content) do
    content
    |> String.replace(~r/^surfer\s+create\s+issue:\s*/i, "")
    |> String.trim()
    |> case do
      "" -> "Discord request"
      title -> title
    end
  end

  defp description_from_message(message) do
    """
    Created from Discord message #{Map.get(message, "id")}.

    Channel: #{Map.get(message, "channel_id")}
    Thread: #{Map.get(message, "thread_id") || "n/a"}

    #{Map.get(message, "content", "")}
    """
  end

  defp issue_message(%{identifier: identifier, url: url}), do: "Created Linear issue #{identifier}: #{url}"
  defp issue_message(issue), do: "Created Linear issue #{inspect(issue)}"
end
