defmodule SymphonyElixir.Surfer.Discord.Ingress do
  @moduledoc """
  Discord ingress normalization and authorization.
  """

  require Logger

  alias SymphonyElixir.Surfer.RunRequest

  @max_age_seconds 300

  @type relay_secret_slot :: String.t() | {atom(), String.t()}

  @spec verify_message_signature(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | [relay_secret_slot()] | nil,
          keyword()
        ) ::
          :ok | {:error, atom()}
  def verify_message_signature(_body, _signature, _timestamp, nil, _opts), do: {:error, :missing_secret}
  def verify_message_signature(_body, _signature, _timestamp, "", _opts), do: {:error, :missing_secret}
  def verify_message_signature(_body, nil, _timestamp, _secrets, _opts), do: {:error, :missing_signature}
  def verify_message_signature(_body, _signature, nil, _secrets, _opts), do: {:error, :missing_timestamp}

  def verify_message_signature(body, signature, timestamp, secrets, opts)
      when is_binary(body) and is_binary(signature) and is_binary(timestamp) and is_list(secrets) do
    case normalize_slots(secrets) do
      [] ->
        {:error, :missing_secret}

      slots ->
        with :ok <- verify_timestamp(timestamp, opts),
             {:ok, signature} <- normalize_signature(signature) do
          verify_secret_slots(body, signature, timestamp, slots)
        end
    end
  end

  def verify_message_signature(body, signature, timestamp, secret, opts)
      when is_binary(body) and is_binary(signature) and is_binary(timestamp) and is_binary(secret) do
    with :ok <- verify_timestamp(timestamp, opts),
         {:ok, signature} <- normalize_signature(signature) do
      verify_signature(body, signature, timestamp, secret)
    end
  end

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
        message
        |> put_received_at(Keyword.get(opts, :received_at))
        |> RunRequest.from_discord_message()
    end
  end

  defp put_received_at(message, received_at) when is_binary(received_at) do
    Map.put(message, "timestamp", received_at)
  end

  defp put_received_at(message, _received_at), do: message

  defp verify_timestamp(timestamp, opts) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        age_seconds = abs(System.system_time(:second) - seconds)

        if age_seconds <= max_age_seconds(opts) do
          :ok
        else
          {:error, :stale_timestamp}
        end

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  defp max_age_seconds(opts) do
    case Keyword.get(opts, :max_age_seconds, @max_age_seconds) do
      value when is_integer(value) and value > 0 -> value
      _value -> @max_age_seconds
    end
  end

  defp normalize_signature("sha256=" <> signature), do: normalize_signature(signature)

  defp normalize_signature(signature) do
    signature = String.downcase(signature)

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, signature) do
      {:ok, signature}
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_secret_slots(body, signature, timestamp, slots) do
    case Enum.find(slots, fn {_slot, secret} -> verify_signature(body, signature, timestamp, secret) == :ok end) do
      {slot, _secret} ->
        Logger.debug("Discord message relay signature matched secret_slot=#{slot}")
        :ok

      nil ->
        {:error, :invalid_signature}
    end
  end

  defp verify_signature(body, signature, timestamp, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp normalize_slots(secrets) do
    secrets
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{slot, secret}, _index} when is_atom(slot) and is_binary(secret) ->
        normalize_slot(slot, secret)

      {secret, 0} when is_binary(secret) ->
        normalize_slot(:current, secret)

      {secret, 1} when is_binary(secret) ->
        normalize_slot(:next, secret)

      {secret, index} when is_binary(secret) ->
        normalize_slot(:"slot_#{index}", secret)

      _other ->
        []
    end)
  end

  defp normalize_slot(slot, secret) do
    if String.trim(secret) == "", do: [], else: [{slot, secret}]
  end
end
