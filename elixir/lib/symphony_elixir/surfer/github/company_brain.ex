defmodule SymphonyElixir.Surfer.GitHub.CompanyBrain do
  @moduledoc """
  Scoped Company Brain retrieval boundary for Surfer prompt context.
  """

  alias SymphonyElixir.Surfer.SecretRedactor

  @max_summary_length 500

  @spec retrieve(map()) :: {:ok, [map()]} | {:error, term()}
  def retrieve(%{company_brain_repo: repo, company_brain_paths: paths, fetch_fun: fetch_fun})
      when is_binary(repo) and is_list(paths) and is_function(fetch_fun, 2) do
    with {:ok, refs} <- fetch_fun.(repo, paths) do
      {:ok, refs |> Enum.filter(&allowed_path?(&1, paths)) |> Enum.map(&background_ref/1)}
    end
  end

  def retrieve(_config), do: {:ok, []}

  defp background_ref(ref) when is_map(ref) do
    %{}
    |> put_present(:path, string_value(ref, :path))
    |> put_present(:url, string_value(ref, :url))
    |> put_present(:summary, ref |> string_value(:summary) |> sanitize_summary())
    |> Map.put(:authority, :background)
    |> Map.put(:role, :background_context)
    |> Map.put(:authoritative?, false)
  end

  defp allowed_path?(ref, paths) when is_map(ref) do
    path = string_value(ref, :path)

    is_binary(path) and Enum.any?(paths, &String.starts_with?(path, &1))
  end

  defp string_value(ref, key) when is_map(ref) do
    case Map.get(ref, key) || Map.get(ref, to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp sanitize_summary(nil), do: nil

  defp sanitize_summary(summary) when is_binary(summary) do
    summary
    |> SecretRedactor.redact_text()
    |> truncate_summary()
  end

  defp truncate_summary(summary) when is_binary(summary) do
    if String.length(summary) > @max_summary_length do
      String.slice(summary, 0, @max_summary_length) <> "..."
    else
      summary
    end
  end
end
