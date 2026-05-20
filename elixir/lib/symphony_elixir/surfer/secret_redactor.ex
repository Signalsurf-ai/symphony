defmodule SymphonyElixir.Surfer.SecretRedactor do
  @moduledoc """
  Redacts bearer credentials from Surfer operational data.
  """

  @redacted "[REDACTED]"
  @safe_token_usage_keys MapSet.new([
                           "cachedinputtokens",
                           "inputtokens",
                           "outputtokens",
                           "reasoningtokens",
                           "totaltokens",
                           "totaltokenusage",
                           "tokenusage"
                         ])

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
    |> String.replace(~r/\b(authorization\s*(?::|=>|=)\s*(?:bearer|bot)\s+)[^\s<>"']+/i, "\\1#{@redacted}")
    |> String.replace(~r/\b(bearer\s+)[^\s<>"']+/i, "\\1#{@redacted}")
    |> redact_secret_assignments()
    |> String.replace(~r/xox[a-zA-Z]-[A-Za-z0-9-]+/, @redacted)
  end

  defp redact_secret_assignments(value) do
    Regex.replace(secret_assignment_regex(), value, fn match, prefix, key ->
      if secret_key?(key), do: prefix <> @redacted, else: match
    end)
  end

  defp secret_key?(key) do
    normalized_key = normalized_key(key)

    if MapSet.member?(@safe_token_usage_keys, normalized_key) do
      false
    else
      Enum.any?(
        ["token", "secret", "authorization", "api_key", "apikey", "api-key", "password", "credential", "oauth"],
        fn fragment -> String.contains?(normalized_key, normalized_key(fragment)) end
      )
    end
  end

  defp normalized_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp secret_assignment_regex do
    ~r/(?<![A-Za-z0-9_.-])(["']?([A-Za-z0-9_.-]*(?:discord_interaction_token|interaction_token|oauth[_-]?token|webhook[_-]?secret|access[_-]?token|refresh[_-]?token|bot[_-]?token|api[_-]?key|token|secret|password)[A-Za-z0-9_.-]*)["']?\s*[:=]\s*["']?)[^\s<>"',}]+/i
  end
end
