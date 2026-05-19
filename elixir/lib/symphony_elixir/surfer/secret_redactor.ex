defmodule SymphonyElixir.Surfer.SecretRedactor do
  @moduledoc """
  Redacts bearer credentials from Surfer operational data.
  """

  @redacted "[REDACTED]"

  @spec redact(term()) :: term()
  def redact(%_struct{} = value), do: value |> inspect() |> redact_text()

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact(nested)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value), do: redact_text(value)
  def redact(value), do: value

  @spec redact_text(String.t()) :: String.t()
  def redact_text(value) when is_binary(value) do
    value
    |> String.replace(~r{(discord(?:app)?\.com/api/v\d+/webhooks/[^/\s<>"']+/)[^/\s<>"']+}i, "\\1#{@redacted}")
    |> String.replace(~r/\b(authorization\s*:\s*(?:bearer|bot)\s+)[^\s<>"']+/i, "\\1#{@redacted}")
    |> String.replace(~r/\b(bearer\s+)[^\s<>"']+/i, "\\1#{@redacted}")
    |> String.replace(secret_assignment_regex(), "\\1#{@redacted}")
    |> String.replace(~r/xox[a-zA-Z]-[A-Za-z0-9-]+/, @redacted)
  end

  defp secret_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(fn key ->
      Enum.any?(
        ["token", "secret", "authorization", "api_key", "apikey", "api-key", "password", "credential", "oauth"],
        &String.contains?(key, &1)
      )
    end)
  end

  defp secret_assignment_regex do
    ~r/\b((?:discord_interaction_token|interaction_token|oauth_token|webhook_secret|access_token|refresh_token|bot_token|api[_-]?key|token|secret|password)\s*[:=]\s*["']?)[^\s<>"']+/i
  end
end
