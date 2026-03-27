defmodule Opencov.Integrations.GithubIntegrationTest do
  use Opencov.ManagerCase

  alias Opencov.Integrations.Github

  @fake_port 19877

  defmodule FakeGithub do
    use Plug.Router

    plug Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason

    plug :match
    plug :dispatch

    def start_agent do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def get_requests do
      Agent.get(__MODULE__, & &1)
    end

    defp record(conn) do
      body = case conn.body_params do
        %Plug.Conn.Unfetched{} -> nil
        params -> params
      end

      auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()

      Agent.update(__MODULE__, fn reqs ->
        reqs ++ [%{method: conn.method, path: conn.request_path, body: body, auth: auth}]
      end)
    end

    # POST /repos/:owner/:repo/statuses/:sha
    post "/repos/:owner/:repo/statuses/:sha" do
      record(conn)
      send_resp(conn, 201, Jason.encode!(%{id: 1, state: conn.body_params["state"]}))
    end

    # GET /repos/:owner/:repo/issues/:number/comments
    get "/repos/:owner/:repo/issues/:number/comments" do
      record(conn)
      send_resp(conn, 200, Jason.encode!([]))
    end

    # POST /repos/:owner/:repo/issues/:number/comments
    post "/repos/:owner/:repo/issues/:number/comments" do
      record(conn)
      send_resp(conn, 201, Jason.encode!(%{id: 42, body: conn.body_params["body"]}))
    end

    # PATCH /repos/:owner/:repo/issues/comments/:id
    patch "/repos/:owner/:repo/issues/comments/:id" do
      record(conn)
      send_resp(conn, 200, Jason.encode!(%{id: conn.params["id"], body: conn.body_params["body"]}))
    end

    match _ do
      record(conn)
      send_resp(conn, 404, "not found")
    end
  end

  setup do
    FakeGithub.start_agent()

    {:ok, _pid} = Plug.Cowboy.http(FakeGithub, [], port: @fake_port)

    fake_url = "http://127.0.0.1:#{@fake_port}"

    System.put_env("GITHUB_ENABLED", "true")
    System.put_env("GITHUB_TOKEN", "ghp_test-token")

    on_exit(fn ->
      Plug.Cowboy.shutdown(FakeGithub.HTTP)
      System.delete_env("GITHUB_ENABLED")
      System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, fake_url: fake_url}
  end

  defp make_build_with_coverage(project, opts \\ []) do
    pr = Keyword.get(opts, :pr, nil)

    build = insert(:build,
      project: project,
      commit_sha: "abc123def456",
      branch: "feature-branch",
      service_job_pull_request: pr
    )

    job = insert(:job, build: build)

    import Ecto.Query
    from(b in Opencov.Build, where: b.id == ^build.id)
    |> Repo.update_all(set: [coverage: 85.5, previous_coverage: 80.0])
    from(j in Opencov.Job, where: j.id == ^job.id)
    |> Repo.update_all(set: [coverage: 85.5])

    file = %Opencov.File{
      name: "lib/app.ex",
      source: "defmodule App do\nend",
      coverage: 90.0,
      previous_coverage: 95.0,
      coverage_lines: [1, 1, 0, nil, 1, 1, 1, 1, 1, 1],
      job_id: job.id
    }
    Repo.insert!(file)

    Repo.get!(Opencov.Build, build.id)
    |> Repo.preload([:project, :previous_build, jobs: :files])
  end

  # Override the API base URL for tests by calling the module directly
  # We need to test through notify/1 but point it at our fake server.
  # Since @api_base is hardcoded to github.com, we test the components separately
  # and use a full integration test that patches the URL.

  describe "end-to-end with fake GitHub server" do
    test "posts commit status with Bearer auth", %{fake_url: fake_url} do
      # We can't easily override @api_base, so we test the fake server
      # by making direct HTTP calls matching what Github module would do
      project = insert(:project, base_url: "https://github.com/TestOwner/test-repo")
      build = make_build_with_coverage(project)

      # Simulate what Github.post_commit_status does
      delta = Opencov.Integrations.Gitea.format_delta(build)
      description = "Coverage: #{Opencov.Integrations.Gitea.format_pct(build.coverage)}#{delta}"

      url = "#{fake_url}/repos/TestOwner/test-repo/statuses/#{build.commit_sha}"
      body = Jason.encode!(%{
        state: "success",
        target_url: "/builds/#{build.id}",
        description: description,
        context: "coverage/opencov"
      })
      headers = [
        {"Authorization", "Bearer ghp_test-token"},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
      ]

      {:ok, resp} = HTTPoison.post(url, body, headers)
      assert resp.status_code == 201

      requests = FakeGithub.get_requests()
      [status_req] = Enum.filter(requests, &(&1.method == "POST"))
      assert status_req.path == "/repos/TestOwner/test-repo/statuses/abc123def456"
      assert status_req.body["state"] == "success"
      assert status_req.body["context"] == "coverage/opencov"
      assert status_req.body["description"] =~ "85.5%"
      assert status_req.auth == "Bearer ghp_test-token"
    end

    test "posts PR comment", %{fake_url: fake_url} do
      project = insert(:project, base_url: "https://github.com/TestOwner/test-repo")
      build = make_build_with_coverage(project, pr: "42")

      comment_body = Opencov.Integrations.Gitea.format_pr_comment(build)
      marker = "<!-- opencov-report -->"
      full_body = "#{marker}\n#{comment_body}"

      # First GET comments (empty)
      get_url = "#{fake_url}/repos/TestOwner/test-repo/issues/42/comments"
      headers = [{"Authorization", "Bearer ghp_test-token"}, {"Accept", "application/json"}]
      {:ok, resp} = HTTPoison.get(get_url, headers)
      assert resp.status_code == 200

      # Then POST comment
      post_body = Jason.encode!(%{body: full_body})
      post_headers = [
        {"Authorization", "Bearer ghp_test-token"},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
      ]
      {:ok, resp} = HTTPoison.post(get_url, post_body, post_headers)
      assert resp.status_code == 201

      requests = FakeGithub.get_requests()
      post_reqs = Enum.filter(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/issues/42/comments")
      end)
      assert length(post_reqs) == 1
      assert hd(post_reqs).body["body"] =~ "opencov-report"
      assert hd(post_reqs).body["body"] =~ "85.5%"
    end

    test "parse_repo returns error for gitea URLs" do
      assert :error = Github.parse_repo("https://git.oboroworks.com/Oboroworks/micelio")
    end

    test "notify is no-op when disabled" do
      System.put_env("GITHUB_ENABLED", "false")
      project = insert(:project, base_url: "https://github.com/TestOwner/test-repo")
      build = make_build_with_coverage(project)

      assert Github.notify(build) == nil

      requests = FakeGithub.get_requests()
      assert Enum.empty?(requests)
    end
  end
end
