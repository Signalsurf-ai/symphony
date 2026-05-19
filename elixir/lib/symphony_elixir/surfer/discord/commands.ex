defmodule SymphonyElixir.Surfer.Discord.Commands do
  @moduledoc """
  Discord application command payloads for Surfer.
  """

  @discord_api "https://discord.com/api/v10"

  @chat_input_command 1
  @subcommand_option 1
  @string_option 3

  @prompt_commands [
    {"ask", "Ask a read-only code question."},
    {"issue", "Create a Linear issue from a Discord request."},
    {"run", "Create a Linear issue and start a durable coding task."}
  ]

  @lifecycle_commands [
    {"cancel", "Request cancellation for a Surfer run."},
    {"retry", "Request a new linked run after failure."}
  ]

  @spec application_command() :: map()
  def application_command do
    %{
      name: "surfer",
      description: "Ask Surfer or delegate coding work.",
      type: @chat_input_command,
      options:
        Enum.map(@prompt_commands, &prompt_subcommand/1) ++
          Enum.map(@lifecycle_commands, &lifecycle_subcommand/1)
    }
  end

  @spec register_guild_command(map()) :: {:ok, map()} | {:error, term()}
  def register_guild_command(attrs), do: register_guild_command(attrs, [])

  @spec register_guild_command(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register_guild_command(attrs, opts) when is_map(attrs) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/3)

    with {:ok, application_id} <- present(value(attrs, :application_id), :missing_discord_application_id),
         {:ok, guild_id} <- present(value(attrs, :guild_id), :missing_discord_guild_id),
         {:ok, bot_token} <- present(value(attrs, :bot_token), :missing_discord_bot_token) do
      request_fun.(
        "#{@discord_api}/applications/#{application_id}/guilds/#{guild_id}/commands",
        headers(bot_token),
        application_command()
      )
    end
  end

  def register_guild_command(_attrs, _opts), do: {:error, :invalid_discord_command_registration}

  defp prompt_subcommand({name, description}) do
    %{
      name: name,
      description: description,
      type: @subcommand_option,
      options: [
        %{
          name: "prompt",
          description: "Request text for Surfer.",
          type: @string_option,
          required: true
        }
      ]
    }
  end

  defp lifecycle_subcommand({name, description}) do
    %{
      name: name,
      description: description,
      type: @subcommand_option,
      options: [
        %{
          name: "run_id",
          description: "Surfer run ID.",
          type: @string_option,
          required: true
        }
      ]
    }
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp present(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, error), do: {:error, error}

  defp headers(token) do
    [
      {"authorization", "Bot #{token}"},
      {"content-type", "application/json"}
    ]
  end

  defp default_request(url, headers, body) do
    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 -> {:ok, response_body}
      {:ok, %{status: status, body: response_body}} -> {:error, {:discord_status, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
