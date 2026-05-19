defmodule SymphonyElixir.Surfer.Discord.Webhook do
  @moduledoc """
  Verifies Discord HTTP interaction signatures.
  """

  require Logger

  @max_age_seconds 300

  @type public_key_slot :: String.t() | {atom(), String.t()}

  @spec verify(String.t(), String.t() | nil, String.t() | nil, String.t() | [public_key_slot()] | nil) ::
          :ok | {:error, atom()}
  def verify(body, signature, timestamp, public_key), do: verify(body, signature, timestamp, public_key, [])

  @spec verify(String.t(), String.t() | nil, String.t() | nil, String.t() | [public_key_slot()] | nil, keyword()) ::
          :ok | {:error, atom()}
  def verify(_body, _signature, _timestamp, nil, _opts), do: {:error, :missing_public_key}
  def verify(_body, _signature, _timestamp, "", _opts), do: {:error, :missing_public_key}
  def verify(_body, nil, _timestamp, _public_key, _opts), do: {:error, :missing_signature}
  def verify(_body, _signature, nil, _public_key, _opts), do: {:error, :missing_timestamp}

  def verify(body, signature, timestamp, public_keys, opts)
      when is_binary(body) and is_binary(signature) and is_binary(timestamp) and is_list(public_keys) do
    case normalize_slots(public_keys) do
      [] ->
        {:error, :missing_public_key}

      slots ->
        with :ok <- verify_timestamp(timestamp, opts),
             {:ok, decoded_signature} <- decode_hex(signature) do
          verify_public_key_slots(body, decoded_signature, timestamp, slots)
        end
    end
  end

  def verify(body, signature, timestamp, public_key, opts)
      when is_binary(body) and is_binary(signature) and is_binary(timestamp) and is_binary(public_key) do
    with :ok <- verify_timestamp(timestamp, opts),
         {:ok, decoded_signature} <- decode_hex(signature),
         {:ok, decoded_public_key} <- decode_hex(public_key),
         true <- :crypto.verify(:eddsa, :none, timestamp <> body, decoded_signature, [decoded_public_key, :ed25519]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_signature}
    end
  end

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

  defp decode_hex(value) do
    case Base.decode16(String.upcase(value), case: :upper) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_signature}
    end
  end

  defp verify_public_key_slots(body, decoded_signature, timestamp, slots) do
    case Enum.find(slots, fn {_slot, public_key} -> public_key_matches?(body, decoded_signature, timestamp, public_key) end) do
      {slot, _public_key} ->
        Logger.debug("Discord webhook signature matched public_key_slot=#{slot}")
        :ok

      nil ->
        {:error, :invalid_signature}
    end
  end

  defp public_key_matches?(body, decoded_signature, timestamp, public_key) do
    case decode_hex(public_key) do
      {:ok, decoded_public_key} ->
        :crypto.verify(:eddsa, :none, timestamp <> body, decoded_signature, [decoded_public_key, :ed25519])

      {:error, _reason} ->
        false
    end
  end

  defp normalize_slots(public_keys) do
    public_keys
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{slot, public_key}, _index} when is_atom(slot) and is_binary(public_key) ->
        normalize_slot(slot, public_key)

      {public_key, 0} when is_binary(public_key) ->
        normalize_slot(:current, public_key)

      {public_key, 1} when is_binary(public_key) ->
        normalize_slot(:next, public_key)

      {public_key, index} when is_binary(public_key) ->
        normalize_slot(:"slot_#{index}", public_key)

      _other ->
        []
    end)
  end

  defp normalize_slot(slot, public_key) do
    if String.trim(public_key) == "", do: [], else: [{slot, public_key}]
  end
end
