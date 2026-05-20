defmodule SymphonyElixir.Surfer.GitHub.CompanyBrain do
  @moduledoc """
  Scoped Company Brain retrieval boundary for Surfer prompt context.
  """

  alias SymphonyElixir.Surfer.SecretRedactor

  @max_summary_length 500

  @spec retrieve(map()) :: {:ok, [map()]} | {:error, term()}
  def retrieve(%{company_brain_repo: repo, company_brain_paths: paths, fetch_fun: fetch_fun})
      when is_binary(repo) and is_list(paths) and is_function(fetch_fun, 2) do
    allowed_paths = normalize_allowed_paths(paths)

    with {:ok, refs} <- fetch_fun.(repo, allowed_paths) do
      {:ok, refs |> Enum.filter(&allowed_path?(&1, allowed_paths)) |> Enum.map(&background_ref(&1, repo))}
    end
  end

  def retrieve(_config), do: {:ok, []}

  defp background_ref(ref, repo) when is_map(ref) do
    %{}
    |> put_present(:repo, repo)
    |> put_present(:path, sanitized_string_value(ref, :path))
    |> put_present(:commit, sanitized_string_value(ref, :commit))
    |> put_present(:freshness, sanitized_string_value(ref, :freshness))
    |> put_present(:url, sanitized_string_value(ref, :url))
    |> put_present(:summary, ref |> string_value(:summary) |> sanitize_summary())
    |> Map.put(:authority, :background)
    |> Map.put(:role, :background_context)
    |> Map.put(:authoritative?, false)
  end

  defp allowed_path?(ref, allowed_paths) when is_map(ref) do
    with path when is_binary(path) <- ref |> string_value(:path) |> safe_repo_path() do
      Enum.any?(allowed_paths, &path_allowed?(path, &1))
    end
  end

  defp normalize_allowed_paths(paths) do
    paths
    |> Enum.map(&safe_repo_path/1)
    |> Enum.reject(&is_nil/1)
  end

  defp path_allowed?(path, allowed_path), do: path == allowed_path or String.starts_with?(path, allowed_path <> "/")

  defp safe_repo_path(path) when is_binary(path) do
    path = String.trim(path)
    segments = String.split(path, "/", trim: true)

    cond do
      path == "" -> nil
      String.starts_with?(path, "/") -> nil
      Enum.any?(segments, &(&1 in [".", ".."])) -> nil
      true -> Enum.join(segments, "/")
    end
  end

  defp safe_repo_path(_path), do: nil

  defp string_value(ref, key) when is_map(ref) do
    case Map.get(ref, key) || Map.get(ref, to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp sanitized_string_value(ref, key) do
    ref
    |> string_value(key)
    |> sanitize_provenance_value()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp sanitize_summary(nil), do: nil

  defp sanitize_summary(summary) when is_binary(summary) do
    summary
    |> sanitize_provenance_value()
    |> truncate_summary()
  end

  defp sanitize_provenance_value(nil), do: nil
  defp sanitize_provenance_value(value) when is_binary(value), do: SecretRedactor.redact_text(value)

  defp truncate_summary(summary) when is_binary(summary) do
    if String.length(summary) > @max_summary_length do
      String.slice(summary, 0, @max_summary_length) <> "..."
    else
      summary
    end
  end
end
