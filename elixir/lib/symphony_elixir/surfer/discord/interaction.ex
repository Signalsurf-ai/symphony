defmodule SymphonyElixir.Surfer.Discord.Interaction do
  @moduledoc """
  Normalizes Discord application command interactions into Surfer run requests.
  """

  alias SymphonyElixir.Surfer.RunRequest

  @ping 1
  @application_command 2

  @spec ping?(map()) :: boolean()
  def ping?(%{"type" => @ping}), do: true
  def ping?(_interaction), do: false

  @spec to_run_request(map()) :: {:ok, RunRequest.t()} | {:error, term()}
  def to_run_request(interaction), do: to_run_request(interaction, [])

  @spec to_run_request(map(), keyword()) :: {:ok, RunRequest.t()} | {:error, term()}
  def to_run_request(%{"type" => @application_command} = interaction, opts) do
    allowed_guilds = Keyword.get(opts, :allowed_guilds, [])
    allowed_channels = Keyword.get(opts, :allowed_channels, [])

    with :ok <- authorize("guild", Map.get(interaction, "guild_id"), allowed_guilds),
         :ok <- authorize("channel", Map.get(interaction, "channel_id"), allowed_channels) do
      command = command(interaction)
      {:ok, request} = interaction |> interaction_message(command) |> RunRequest.from_discord_message()
      request = apply_command(request, command)
      request = put_in(request.request[:trigger_type], :slash_command)
      interaction_id = Map.get(interaction, "id")

      {:ok,
       %{
         request
         | source: %{
             request.source
             | trigger_type: :slash_command,
               raw_event_id: interaction_id,
               natural_event_key: interaction_natural_event_key(interaction_id, request.request.mode)
           },
           lineage:
             put_in(
               request.lineage,
               [:discord],
               Map.merge(request.lineage.discord, %{
                 interaction_id: Map.get(interaction, "id"),
                 application_id: Map.get(interaction, "application_id")
               })
             )
       }}
    end
  end

  def to_run_request(%{"type" => type}, _opts), do: {:error, {:unsupported_interaction_type, type}}
  def to_run_request(_interaction, _opts), do: {:error, :invalid_interaction}

  defp authorize(_kind, _id, []), do: :ok

  defp authorize(kind, id, allowed) when is_binary(id) do
    if id in allowed, do: :ok, else: unauthorized(kind, id)
  end

  defp authorize("guild", id, _allowed), do: {:error, {:unauthorized_guild, id}}
  defp authorize("channel", id, _allowed), do: {:error, {:unauthorized_channel, id}}

  defp unauthorized("guild", id), do: {:error, {:unauthorized_guild, id}}
  defp unauthorized("channel", id), do: {:error, {:unauthorized_channel, id}}

  defp interaction_message(interaction, command) do
    %{
      "id" => Map.get(interaction, "id"),
      "guild_id" => Map.get(interaction, "guild_id"),
      "channel_id" => Map.get(interaction, "channel_id"),
      "thread_id" => get_in(interaction, ["channel", "thread_metadata", "id"]),
      "author" => %{"id" => user_id(interaction)},
      "content" => command.prompt || command.run_id || ""
    }
  end

  defp interaction_natural_event_key(interaction_id, mode) do
    Enum.map_join(["discord_interaction", interaction_id || "unknown_interaction", mode], ":", &to_string/1)
  end

  defp user_id(interaction) do
    get_in(interaction, ["member", "user", "id"]) || get_in(interaction, ["user", "id"])
  end

  defp command(interaction) do
    interaction
    |> get_in(["data", "options"])
    |> parse_command_options()
  end

  defp parse_command_options([%{"type" => 1, "name" => name, "options" => options} | _])
       when name in ["ask", "issue", "run", "cancel", "retry"] do
    %{
      name: name,
      prompt: option_value(options, "prompt") || option_value(options, "request"),
      run_id: option_value(options, "run_id")
    }
  end

  defp parse_command_options([%{type: 1, name: name, options: options} | _])
       when name in ["ask", "issue", "run", "cancel", "retry"] do
    %{
      name: name,
      prompt: option_value(options, "prompt") || option_value(options, "request"),
      run_id: option_value(options, "run_id")
    }
  end

  defp parse_command_options(options) do
    %{
      name: nil,
      prompt: option_value(options, "prompt") || option_value(options, "request"),
      run_id: option_value(options, "run_id")
    }
  end

  defp apply_command(request, %{name: "ask", prompt: prompt}) do
    put_request(request, :code_question, :slash_command, prompt || "")
  end

  defp apply_command(request, %{name: "issue", prompt: prompt}) do
    put_request(request, :issue_create, :slash_command, prompt || "")
  end

  defp apply_command(request, %{name: "run", prompt: prompt}) do
    put_request(request, :durable_task, :slash_command, prompt || "")
  end

  defp apply_command(request, %{name: action, run_id: run_id}) when action in ["cancel", "retry"] do
    %{
      request
      | request:
          Map.merge(request.request, %{
            mode: :lifecycle_control,
            trigger_type: :slash_command,
            action: String.to_atom(action),
            run_id: run_id,
            title: "Surfer #{action} #{run_id}",
            body: run_id || ""
          }),
        constraints: RunRequest.constraints_for(:lifecycle_control, :discord)
    }
  end

  defp apply_command(request, _command), do: request

  defp put_request(request, mode, trigger_type, body) do
    %{
      request
      | request:
          Map.merge(request.request, %{
            mode: mode,
            trigger_type: trigger_type,
            title: if(body == "", do: "Discord request", else: body),
            body: body
          }),
        constraints: RunRequest.constraints_for(mode, :discord)
    }
  end

  defp option_value(options, name) when is_list(options) do
    options
    |> Enum.find(&(Map.get(&1, "name") == name || Map.get(&1, :name) == name))
    |> case do
      nil -> nil
      option -> Map.get(option, "value") || Map.get(option, :value)
    end
  end

  defp option_value(_options, _name), do: nil
end
