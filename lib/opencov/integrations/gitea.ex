defmodule Opencov.Integrations.Gitea do
  @moduledoc """
  Gitea integration: posts commit status and PR comments after coverage processing.
  """

  require Logger

  def notify(build) do
    config = Application.get_env(:opencov, :gitea, [])
    if config[:enabled] && config[:url] && config[:token] do
      Task.start(fn -> do_notify(build, config) end)
    end
  end

  defp do_notify(build, config) do
    build = Opencov.Repo.preload(build, [:project, jobs: :files])

    case parse_repo(build.project.base_url, config[:url]) do
      {:ok, owner, repo} ->
        if config[:post_commit_status] && build.commit_sha do
          post_commit_status(config, owner, repo, build)
        end

        if config[:post_pr_comment] && build.service_job_pull_request do
          post_pr_comment(config, owner, repo, build)
        end

      :error ->
        Logger.warning("Gitea: cannot parse repo from base_url=#{build.project.base_url}")
    end
  end

  defp parse_repo(base_url, gitea_url) do
    gitea_host = URI.parse(gitea_url).host
    uri = URI.parse(base_url)

    if uri.host == gitea_host do
      parts = uri.path |> String.trim_leading("/") |> String.trim_trailing(".git") |> String.split("/")
      case parts do
        [owner, repo | _] -> {:ok, owner, repo}
        _ -> :error
      end
    else
      :error
    end
  end

  # --- Commit Status ---

  defp post_commit_status(config, owner, repo, build) do
    delta = format_delta(build)
    state = "success"
    description = "Coverage: #{format_pct(build.coverage)}#{delta}"
    target_url = build_url(build)

    url = "#{config[:url]}/api/v1/repos/#{owner}/#{repo}/statuses/#{build.commit_sha}"
    body = Jason.encode!(%{
      state: state,
      target_url: target_url,
      description: description,
      context: "coverage/opencov"
    })

    case api_request(:post, url, body, config[:token]) do
      {:ok, _} -> Logger.info("Gitea: posted commit status for #{build.commit_sha}")
      {:error, reason} -> Logger.error("Gitea: failed to post commit status: #{inspect(reason)}")
    end
  end

  # --- PR Comment ---

  defp post_pr_comment(config, owner, repo, build) do
    pr_number = build.service_job_pull_request
    comment_body = format_pr_comment(build)
    marker = "<!-- opencov-report -->"
    full_body = "#{marker}\n#{comment_body}"

    url = "#{config[:url]}/api/v1/repos/#{owner}/#{repo}/issues/#{pr_number}/comments"

    # Check for existing comment to update
    case find_existing_comment(config, owner, repo, pr_number, marker) do
      {:ok, comment_id} ->
        edit_url = "#{config[:url]}/api/v1/repos/#{owner}/#{repo}/issues/comments/#{comment_id}"
        body = Jason.encode!(%{body: full_body})
        case api_request(:patch, edit_url, body, config[:token]) do
          {:ok, _} -> Logger.info("Gitea: updated PR comment for PR ##{pr_number}")
          {:error, reason} -> Logger.error("Gitea: failed to update PR comment: #{inspect(reason)}")
        end

      :not_found ->
        body = Jason.encode!(%{body: full_body})
        case api_request(:post, url, body, config[:token]) do
          {:ok, _} -> Logger.info("Gitea: posted PR comment for PR ##{pr_number}")
          {:error, reason} -> Logger.error("Gitea: failed to post PR comment: #{inspect(reason)}")
        end
    end
  end

  defp find_existing_comment(config, owner, repo, pr_number, marker) do
    url = "#{config[:url]}/api/v1/repos/#{owner}/#{repo}/issues/#{pr_number}/comments"
    case api_request(:get, url, nil, config[:token]) do
      {:ok, %{body: body}} ->
        comments = Jason.decode!(body)
        case Enum.find(comments, fn c -> String.contains?(c["body"] || "", marker) end) do
          nil -> :not_found
          comment -> {:ok, comment["id"]}
        end
      {:error, _} -> :not_found
    end
  end

  # --- Comment Formatting ---

  defp format_pr_comment(build) do
    all_files = build.jobs |> Enum.flat_map(& &1.files)
    target_url = build_url(build)

    # Files that lost coverage
    files_with_reduction = all_files
      |> Enum.filter(fn f -> f.previous_coverage && f.coverage < f.previous_coverage end)
      |> Enum.sort_by(fn f -> f.previous_coverage - f.coverage end)

    # Changed files (new or source changed)
    changed_files = all_files
      |> Enum.filter(fn f -> is_nil(f.previous_coverage) end)

    # Stats
    total_relevant = all_files |> Enum.map(fn f -> Opencov.File.relevant_lines_count(f.coverage_lines || []) end) |> Enum.sum()
    total_covered = all_files |> Enum.map(fn f -> Opencov.File.covered_lines_count(f.coverage_lines || []) end) |> Enum.sum()

    changed_relevant = changed_files |> Enum.map(fn f -> Opencov.File.relevant_lines_count(f.coverage_lines || []) end) |> Enum.sum()
    changed_covered = changed_files |> Enum.map(fn f -> Opencov.File.covered_lines_count(f.coverage_lines || []) end) |> Enum.sum()

    new_missed = files_with_reduction |> Enum.map(fn f ->
      prev_covered = if f.previous_coverage && f.previous_coverage > 0 do
        relevant = Opencov.File.relevant_lines_count(f.coverage_lines || [])
        round(f.previous_coverage * relevant / 100)
      else
        0
      end
      current_covered = Opencov.File.covered_lines_count(f.coverage_lines || [])
      max(0, prev_covered - current_covered)
    end) |> Enum.sum()

    delta = format_delta(build)
    badge_color = cond do
      build.coverage >= 90 -> "brightgreen"
      build.coverage >= 75 -> "green"
      build.coverage >= 60 -> "yellow"
      build.coverage >= 40 -> "orange"
      true -> "red"
    end
    badge_pct = build.coverage |> Float.round(0) |> trunc()

    """
    ## Pull Request Test Coverage Report for [Build #{build.build_number}](#{target_url})

    ---

    ### Details

    - **#{changed_covered}** of **#{changed_relevant}** changed or added relevant lines in **#{length(changed_files)}** files are covered.
    - **#{new_missed}** unchanged lines in **#{length(files_with_reduction)}** files lost coverage.
    - Overall coverage #{delta_direction(build)} (#{delta}) to **#{format_pct(build.coverage)}**

    ---

    #{format_files_table(files_with_reduction, target_url)}

    | **Totals** | ![coverage](https://img.shields.io/badge/coverage-#{badge_pct}%25-#{badge_color}) |
    |---|---|
    | Change from base [Build #{previous_build_number(build)}](#{previous_build_url(build)}): | #{delta} |
    | Covered Lines: | #{total_covered} |
    | Relevant Lines: | #{total_relevant} |

    ---
    """
  end

  defp format_files_table([], _target_url), do: ""
  defp format_files_table(files, target_url) do
    header = """
    | Files with Coverage Reduction | New Missed Lines | % |
    |---|---|---|
    """

    rows = files
      |> Enum.map(fn f ->
        relevant = Opencov.File.relevant_lines_count(f.coverage_lines || [])
        prev_covered = if f.previous_coverage && f.previous_coverage > 0,
          do: round(f.previous_coverage * relevant / 100),
          else: 0
        current_covered = Opencov.File.covered_lines_count(f.coverage_lines || [])
        missed = max(0, prev_covered - current_covered)
        "| [#{f.name}](#{target_url}/source?filename=#{URI.encode(f.name)}) | #{missed} | #{format_pct(f.coverage)} |"
      end)
      |> Enum.join("\n")

    header <> rows <> "\n"
  end

  # --- Helpers ---

  defp format_pct(nil), do: "0%"
  defp format_pct(coverage) do
    "#{Float.round(coverage * 1.0, 2)}%"
  end

  defp format_delta(build) do
    if build.previous_coverage do
      delta = Float.round(build.coverage - build.previous_coverage, 1)
      sign = if delta >= 0, do: "+", else: ""
      "#{sign}#{delta}%"
    else
      ""
    end
  end

  defp delta_direction(build) do
    if build.previous_coverage do
      if build.coverage >= build.previous_coverage, do: "increased", else: "decreased"
    else
      "is"
    end
  end

  defp previous_build_number(build) do
    if build.previous_build_id do
      case Opencov.Repo.get(Opencov.Build, build.previous_build_id) do
        nil -> "N/A"
        prev -> "#{prev.build_number}"
      end
    else
      "N/A"
    end
  end

  defp build_url(build) do
    base = Application.get_env(:opencov, :base_url) || ""
    "#{base}/builds/#{build.id}"
  end

  defp previous_build_url(build) do
    if build.previous_build_id do
      base = Application.get_env(:opencov, :base_url) || ""
      "#{base}/builds/#{build.previous_build_id}"
    else
      "#"
    end
  end

  defp api_request(:get, url, _body, token) do
    headers = [
      {"Authorization", "token #{token}"},
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
      {"Authorization", "token #{token}"},
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
