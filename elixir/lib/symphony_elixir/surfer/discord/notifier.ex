defmodule SymphonyElixir.Surfer.Discord.Notifier do
  @moduledoc """
  Minimal Discord REST notifier used for Surfer status messages.
  """

  @discord_api "https://discord.com/api/v10"

  @spec post_message(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def post_message(channel_id, body, opts \\ [])
      when is_binary(channel_id) and is_binary(body) do
    token = Keyword.get(opts, :bot_token)
    request_fun = Keyword.get(opts, :request_fun, &default_request/3)

    case token do
      token when is_binary(token) and token != "" ->
        request_fun.("#{@discord_api}/channels/#{channel_id}/messages", headers(token), %{content: body})

      _ ->
        {:error, :missing_discord_bot_token}
    end
  end

  @spec edit_original_interaction_response(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def edit_original_interaction_response(application_id, interaction_token, body, opts \\ [])
      when is_binary(application_id) and is_binary(interaction_token) and is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &default_patch_request/3)

    request_fun.(
      "#{@discord_api}/webhooks/#{application_id}/#{interaction_token}/messages/@original",
      [{"content-type", "application/json"}],
      %{content: body}
    )
  end

  defp headers(token) do
    [
      {"authorization", "Bot #{token}"},
      {"content-type", "application/json"}
    ]
  end

  defp default_request(url, headers, body) do
    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: response_body}} -> {:error, {:discord_status, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_patch_request(url, headers, body) do
    case Req.patch(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: response_body}} -> {:error, {:discord_status, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
