defmodule SymphonyElixir.Surfer.Discord.Ingress do
  @moduledoc """
  Discord ingress normalization and authorization.
  """

  alias SymphonyElixir.Surfer.RunRequest

  @spec normalize_message(map(), keyword()) :: {:ok, RunRequest.t()} | {:error, term()}
  def normalize_message(message, opts \\ []) when is_map(message) do
    allowed_guilds = Keyword.get(opts, :allowed_guilds, [])
    allowed_channels = Keyword.get(opts, :allowed_channels, [])
    guild_id = Map.get(message, "guild_id")
    channel_id = Map.get(message, "channel_id")

    cond do
      allowed_guilds != [] and guild_id not in allowed_guilds ->
        {:error, {:unauthorized_guild, guild_id}}

      allowed_channels != [] and channel_id not in allowed_channels ->
        {:error, {:unauthorized_channel, channel_id}}

      true ->
        RunRequest.from_discord_message(message)
    end
  end
end
