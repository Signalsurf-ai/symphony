defmodule SymphonyElixir.Surfer.Linear.Webhook do
  @moduledoc """
  Verifies Linear custom-agent webhook signatures against the raw request body.
  """

  require Logger

  @max_age_ms 60_000

  @type secret_slot :: String.t() | {atom(), String.t()}

  @spec verify(String.t(), String.t() | nil, String.t() | [secret_slot()] | nil) :: :ok | {:error, atom()}
  def verify(_body, _signature, nil), do: {:error, :missing_secret}
  def verify(_body, _signature, ""), do: {:error, :missing_secret}
  def verify(_body, nil, _secret), do: {:error, :missing_signature}

  def verify(body, signature, secrets)
      when is_binary(body) and is_binary(signature) and is_list(secrets) do
    case normalize_slots(secrets) do
      [] ->
        {:error, :missing_secret}

      slots ->
        case verify_timestamp(body) do
          :ok -> verify_signature_slots(body, signature, slots)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def verify(body, signature, secret)
      when is_binary(body) and is_binary(signature) and is_binary(secret) do
    case verify_timestamp(body) do
      :ok -> verify_signature(body, signature, secret)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_timestamp(body) do
    with {:ok, decoded} <- Jason.decode(body),
         timestamp when is_integer(timestamp) <- Map.get(decoded, "webhookTimestamp"),
         age_ms <- abs(System.system_time(:millisecond) - timestamp),
         true <- age_ms <= @max_age_ms do
      :ok
    else
      false -> {:error, :stale_timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp verify_signature(body, signature, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature_slots(body, signature, slots) do
    case Enum.find(slots, fn {_slot, secret} -> verify_signature(body, signature, secret) == :ok end) do
      {slot, _secret} ->
        Logger.debug("Linear webhook signature matched secret_slot=#{slot}")
        :ok

      nil ->
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
