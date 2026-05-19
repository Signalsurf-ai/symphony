defmodule SymphonyElixir.Surfer.GitHub.PullRequest do
  @moduledoc """
  Outbound-only GitHub pull request creation/update helper for Surfer.
  """

  @api_base "https://api.github.com"

  @spec create_or_update(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_or_update(attrs, opts \\ []) when is_map(attrs) do
    api_fun = Keyword.get(opts, :api_fun, &request/4)

    with {:ok, input} <- normalize_input(attrs),
         {:ok, existing_pr} <- find_existing_pr(input, api_fun) do
      create_or_update_existing(input, existing_pr, api_fun)
    end
  end

  @spec review_context(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def review_context(attrs, opts \\ []) when is_map(attrs) do
    api_fun = Keyword.get(opts, :api_fun, &request/4)

    with {:ok, input} <- normalize_review_context_input(attrs),
         {:ok, pr} <- api_fun.(:get, pull_path(input), nil, input.token),
         {:ok, reviews} <- api_fun.(:get, pull_path(input) <> "/reviews", nil, input.token),
         {:ok, comments} <- api_fun.(:get, pull_path(input) <> "/comments", nil, input.token),
         {:ok, files} <- api_fun.(:get, pull_path(input) <> "/files", nil, input.token) do
      {:ok,
       %{
         pull_request: normalize_context_pr(pr),
         reviews: normalize_reviews(reviews),
         comments: normalize_comments(comments),
         files: normalize_files(files),
         provenance: review_context_provenance(input, pr)
       }}
    end
  end

  defp find_existing_pr(input, api_fun) do
    path = "/repos/#{input.owner}/#{input.repo}/pulls?state=open&head=#{URI.encode_www_form(input.owner <> ":" <> input.head)}"

    case api_fun.(:get, path, nil, input.token) do
      {:ok, [%{"number" => _number} = pr | _]} -> {:ok, pr}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_github_response, other}}
    end
  end

  defp create_or_update_existing(input, nil, api_fun) do
    body = %{
      title: input.title,
      head: input.head,
      base: input.base,
      body: input.body,
      maintainer_can_modify: true
    }

    with {:ok, pr} <- api_fun.(:post, "/repos/#{input.owner}/#{input.repo}/pulls", body, input.token) do
      {:ok, normalize_pr(pr)}
    end
  end

  defp create_or_update_existing(input, %{"number" => number}, api_fun) do
    body = %{
      title: input.title,
      body: input.body,
      base: input.base
    }

    with {:ok, pr} <- api_fun.(:patch, "/repos/#{input.owner}/#{input.repo}/pulls/#{number}", body, input.token) do
      {:ok, normalize_pr(pr)}
    end
  end

  defp normalize_input(attrs) do
    with {:ok, owner, repo} <- parse_repo(required(attrs, :repo)),
         {:ok, token} <- present(required(attrs, :token), :missing_github_token),
         {:ok, head} <- present(required(attrs, :head), :missing_github_head),
         {:ok, base} <- present(Map.get(attrs, :base) || Map.get(attrs, "base") || "main", :missing_github_base),
         {:ok, title} <- present(required(attrs, :title), :missing_github_title),
         {:ok, body} <- present(required(attrs, :body), :missing_github_body) do
      {:ok, %{owner: owner, repo: repo, token: token, head: head, base: base, title: title, body: body}}
    end
  end

  defp normalize_review_context_input(attrs) do
    with {:ok, owner, repo} <- parse_repo(required(attrs, :repo)),
         {:ok, token} <- present(required(attrs, :token), :missing_github_token),
         {:ok, number} <- pr_number(attrs) do
      {:ok, %{owner: owner, repo: repo, token: token, number: number}}
    end
  end

  defp pr_number(attrs) do
    attrs
    |> required(:number)
    |> case do
      nil -> required(attrs, :pr_number)
      number -> number
    end
    |> normalize_pr_number()
  end

  defp normalize_pr_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp normalize_pr_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_github_pr_number}
    end
  end

  defp normalize_pr_number(nil), do: {:error, :missing_github_pr_number}
  defp normalize_pr_number(_number), do: {:error, :invalid_github_pr_number}

  defp parse_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, :invalid_github_repo}
    end
  end

  defp parse_repo(_repo), do: {:error, :missing_github_repo}

  defp required(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp present(value, error) when is_binary(value) do
    if String.trim(value) == "", do: {:error, error}, else: {:ok, value}
  end

  defp present(_value, error), do: {:error, error}

  defp normalize_pr(pr) when is_map(pr) do
    %{
      number: Map.get(pr, "number"),
      url: Map.get(pr, "html_url"),
      title: Map.get(pr, "title"),
      state: Map.get(pr, "state")
    }
  end

  defp pull_path(input), do: "/repos/#{input.owner}/#{input.repo}/pulls/#{input.number}"

  defp normalize_context_pr(pr) when is_map(pr) do
    %{
      number: Map.get(pr, "number"),
      url: Map.get(pr, "html_url"),
      title: Map.get(pr, "title"),
      state: Map.get(pr, "state"),
      head_ref: get_in(pr, ["head", "ref"]),
      base_ref: get_in(pr, ["base", "ref"])
    }
  end

  defp normalize_reviews(reviews) when is_list(reviews), do: Enum.map(reviews, &normalize_review/1)
  defp normalize_reviews(_reviews), do: []

  defp normalize_review(review) when is_map(review) do
    %{
      id: Map.get(review, "id"),
      state: Map.get(review, "state"),
      author: get_in(review, ["user", "login"]),
      body: Map.get(review, "body"),
      submitted_at: Map.get(review, "submitted_at"),
      url: Map.get(review, "html_url")
    }
  end

  defp normalize_comments(comments) when is_list(comments), do: Enum.map(comments, &normalize_comment/1)
  defp normalize_comments(_comments), do: []

  defp normalize_comment(comment) when is_map(comment) do
    %{
      id: Map.get(comment, "id"),
      path: Map.get(comment, "path"),
      line: Map.get(comment, "line"),
      author: get_in(comment, ["user", "login"]),
      body: Map.get(comment, "body"),
      url: Map.get(comment, "html_url")
    }
  end

  defp normalize_files(files) when is_list(files), do: Enum.map(files, &normalize_file/1)
  defp normalize_files(_files), do: []

  defp normalize_file(file) when is_map(file) do
    %{
      filename: Map.get(file, "filename"),
      status: Map.get(file, "status"),
      changes: Map.get(file, "changes")
    }
  end

  defp review_context_provenance(input, pr) do
    %{
      repo: "#{input.owner}/#{input.repo}",
      pr_number: input.number,
      source_url: Map.get(pr, "html_url"),
      authority: :github_pr_context
    }
  end

  defp request(method, path, body, token) do
    request =
      Req.new(
        base_url: @api_base,
        auth: {:bearer, token},
        headers: [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
      )

    request
    |> Req.request(method: method, url: path, json: body)
    |> case do
      {:ok, %{status: status, body: response_body}} when status in 200..299 -> {:ok, response_body}
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_http_error, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
