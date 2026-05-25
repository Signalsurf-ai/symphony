defmodule SymphonyElixir.Surfer.RunLog do
  @moduledoc """
  Writes per-run structured JSONL logs for Surfer operator diagnostics.
  """

  alias SymphonyElixir.Surfer.SecretRedactor

  @redacted "[REDACTED]"
  @prompt_body_keys MapSet.new(["body", "content", "description", "prompt", "promptcontext", "rawbody", "rawpayload", "title"])
  @raw_platform_payload_keys MapSet.new(["raw", "platformpayload", "eventpayload", "platformevent", "interactionpayload"])

  @spec append(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(logs_dir, run_id, event) when is_binary(logs_dir) and is_binary(run_id) and is_map(event) do
    with :ok <- validate_run_id(run_id),
         :ok <- File.mkdir_p(logs_dir),
         line <- encode_line(run_id, event),
         :ok <- File.write(path(logs_dir, run_id), line, [:append]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec path(Path.t(), String.t()) :: Path.t()
  def path(logs_dir, run_id) when is_binary(logs_dir) and is_binary(run_id) do
    Path.join(logs_dir, "#{run_id}.jsonl")
  end

  defp encode_line(run_id, event) do
    event
    |> stringify_keys()
    |> Map.put_new("timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("run_id", run_id)
    |> SecretRedactor.redact()
    |> redact_log_payload()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp validate_run_id(run_id) do
    if run_id =~ ~r/\A[A-Za-z0-9._-]+\z/ do
      :ok
    else
      {:error, :invalid_run_id}
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp redact_log_payload(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      cond do
        raw_platform_payload_key?(key) -> {key, @redacted}
        prompt_body_key?(key) -> {key, @redacted}
        true -> {key, redact_log_payload(nested)}
      end
    end)
  end

  defp redact_log_payload(value) when is_list(value), do: Enum.map(value, &redact_log_payload/1)
  defp redact_log_payload(value), do: value

  defp prompt_body_key?(key) do
    MapSet.member?(@prompt_body_keys, lookup_key(key))
  end

  defp raw_platform_payload_key?(key) do
    MapSet.member?(@raw_platform_payload_keys, lookup_key(key))
  end

  defp lookup_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end
end
