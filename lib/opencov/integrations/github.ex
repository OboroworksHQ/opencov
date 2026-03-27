defmodule Opencov.Integrations.Github do
  @moduledoc """
  GitHub integration: posts commit status and PR comments after coverage processing.
  """

  require Logger

  @api_base "https://api.github.com"

  def notify(build) do
    config = get_config()
    if config[:enabled] && config[:token] do
      Task.start(fn ->
        try do
          do_notify(build, config)
        rescue
          e -> Logger.error("GitHub notify failed: #{Exception.message(e)}")
        end
      end)
    end
  end

  defp get_config do
    app_config = Application.get_env(:opencov, :github, [])
    %{
      enabled: (System.get_env("GITHUB_ENABLED") || to_string(app_config[:enabled])) == "true",
      token: System.get_env("GITHUB_TOKEN") || app_config[:token],
      post_commit_status: Keyword.get(app_config, :post_commit_status, true),
      post_pr_comment: Keyword.get(app_config, :post_pr_comment, true)
    }
  end

  defp do_notify(build, config) do
    build = Opencov.Repo.preload(build, [:project, :previous_build, jobs: :files])

    case parse_repo(build.project.base_url) do
      {:ok, owner, repo} ->
        if config[:post_commit_status] && build.commit_sha do
          post_commit_status(config, owner, repo, build)
        end

        pr = build.service_job_pull_request
        if config[:post_pr_comment] && is_binary(pr) && String.trim(pr) != "" do
          post_pr_comment(config, owner, repo, build)
        end

      :error ->
        Logger.warning("GitHub: cannot parse repo from base_url=#{build.project.base_url}")
    end
  end

  @doc false
  def parse_repo(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    if uri.host == "github.com" do
      parts = (uri.path || "") |> String.trim_leading("/") |> String.trim_trailing(".git") |> String.split("/")
      case parts do
        [owner, repo | _] when byte_size(owner) > 0 and byte_size(repo) > 0 -> {:ok, owner, repo}
        _ -> :error
      end
    else
      :error
    end
  end
  def parse_repo(_), do: :error

  # --- Commit Status ---

  defp post_commit_status(config, owner, repo, build) do
    delta = Opencov.Integrations.Gitea.format_delta(build)
    description = "Coverage: #{Opencov.Integrations.Gitea.format_pct(build.coverage)}#{delta}"
    target_url = build_url(build)

    url = "#{@api_base}/repos/#{owner}/#{repo}/statuses/#{build.commit_sha}"
    body = Jason.encode!(%{
      state: "success",
      target_url: target_url,
      description: description,
      context: "coverage/opencov"
    })

    case api_request(:post, url, body, config[:token]) do
      {:ok, _} -> Logger.info("GitHub: posted commit status for #{build.commit_sha}")
      {:error, reason} -> Logger.error("GitHub: failed to post commit status: #{inspect(reason)}")
    end
  end

  # --- PR Comment ---

  defp post_pr_comment(config, owner, repo, build) do
    pr_number = String.trim(build.service_job_pull_request)
    comment_body = Opencov.Integrations.Gitea.format_pr_comment(build)
    marker = "<!-- opencov-report -->"
    full_body = "#{marker}\n#{comment_body}"

    case find_existing_comment(config, owner, repo, pr_number, marker) do
      {:ok, comment_id} ->
        edit_url = "#{@api_base}/repos/#{owner}/#{repo}/issues/comments/#{comment_id}"
        body = Jason.encode!(%{body: full_body})
        case api_request(:patch, edit_url, body, config[:token]) do
          {:ok, _} -> Logger.info("GitHub: updated PR comment for PR ##{pr_number}")
          {:error, reason} -> Logger.error("GitHub: failed to update PR comment: #{inspect(reason)}")
        end

      :not_found ->
        url = "#{@api_base}/repos/#{owner}/#{repo}/issues/#{pr_number}/comments"
        body = Jason.encode!(%{body: full_body})
        case api_request(:post, url, body, config[:token]) do
          {:ok, _} -> Logger.info("GitHub: posted PR comment for PR ##{pr_number}")
          {:error, reason} -> Logger.error("GitHub: failed to post PR comment: #{inspect(reason)}")
        end
    end
  end

  defp find_existing_comment(config, owner, repo, pr_number, marker) do
    url = "#{@api_base}/repos/#{owner}/#{repo}/issues/#{pr_number}/comments"
    case api_request(:get, url, nil, config[:token]) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, comments} when is_list(comments) ->
            case Enum.find(comments, fn c -> String.contains?(c["body"] || "", marker) end) do
              nil -> :not_found
              comment -> {:ok, comment["id"]}
            end
          _ -> :not_found
        end
      {:error, _} -> :not_found
    end
  end

  # --- Helpers ---

  defp build_url(build) do
    base = Application.get_env(:opencov, :base_url) || ""
    "#{base}/builds/#{build.id}"
  end

  defp api_request(:get, url, _body, token) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/json"}
    ]
    case HTTPoison.get(url, headers, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: code} = resp} when code in 200..299 ->
        {:ok, resp}
      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, "HTTP #{code}: #{body}"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp api_request(method, url, body, token) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
    case HTTPoison.request(method, url, body, headers, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: code} = resp} when code in 200..299 ->
        {:ok, resp}
      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} ->
        {:error, "HTTP #{code}: #{resp_body}"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end
end
