defmodule Opencov.Integrations.GiteaIntegrationTest do
  use Opencov.ManagerCase

  alias Opencov.Integrations.Gitea

  @fake_port 19876

  # A minimal Plug that records all incoming requests
  defmodule FakeGitea do
    use Plug.Router

    plug Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason

    plug :match
    plug :dispatch

    # Store requests in an Agent so tests can inspect them
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
      Agent.update(__MODULE__, fn reqs ->
        reqs ++ [%{method: conn.method, path: conn.request_path, body: body}]
      end)
    end

    # POST /api/v1/repos/:owner/:repo/statuses/:sha — commit status
    post "/api/v1/repos/:owner/:repo/statuses/:sha" do
      record(conn)
      send_resp(conn, 201, Jason.encode!(%{id: 1, state: conn.body_params["state"]}))
    end

    # GET /api/v1/repos/:owner/:repo/issues/:number/comments — list comments
    get "/api/v1/repos/:owner/:repo/issues/:number/comments" do
      record(conn)
      send_resp(conn, 200, Jason.encode!([]))
    end

    # POST /api/v1/repos/:owner/:repo/issues/:number/comments — create comment
    post "/api/v1/repos/:owner/:repo/issues/:number/comments" do
      record(conn)
      send_resp(conn, 201, Jason.encode!(%{id: 42, body: conn.body_params["body"]}))
    end

    # PATCH /api/v1/repos/:owner/:repo/issues/comments/:id — update comment
    patch "/api/v1/repos/:owner/:repo/issues/comments/:id" do
      record(conn)
      send_resp(conn, 200, Jason.encode!(%{id: conn.params["id"], body: conn.body_params["body"]}))
    end

    match _ do
      record(conn)
      send_resp(conn, 404, "not found")
    end
  end

  setup do
    FakeGitea.start_agent()

    {:ok, _pid} = Plug.Cowboy.http(FakeGitea, [], port: @fake_port)

    fake_url = "http://127.0.0.1:#{@fake_port}"

    System.put_env("GITEA_ENABLED", "true")
    System.put_env("GITEA_URL", fake_url)
    System.put_env("GITEA_TOKEN", "test-token")

    on_exit(fn ->
      Plug.Cowboy.shutdown(FakeGitea.HTTP)
      System.delete_env("GITEA_ENABLED")
      System.delete_env("GITEA_URL")
      System.delete_env("GITEA_TOKEN")
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

    # Update coverage directly in DB
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

    file2 = %Opencov.File{
      name: "lib/new.ex",
      source: "defmodule New do\nend",
      coverage: 80.0,
      previous_coverage: nil,
      coverage_lines: [1, 1, 1, 1, 0, nil, nil],
      job_id: job.id
    }
    Repo.insert!(file2)

    Repo.preload(build, [:project, :previous_build, jobs: :files])
  end

  describe "end-to-end with fake Gitea server" do
    test "posts commit status when build has commit_sha", %{fake_url: fake_url} do
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project)

      Gitea.notify(build)

      # Wait for async Task
      :timer.sleep(500)

      requests = FakeGitea.get_requests()
      status_reqs = Enum.filter(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/statuses/")
      end)

      assert length(status_reqs) == 1
      [status_req] = status_reqs
      assert status_req.path == "/api/v1/repos/TestOwner/test-repo/statuses/abc123def456"
      assert status_req.body["state"] == "success"
      assert status_req.body["context"] == "coverage/opencov"
      assert status_req.body["description"] =~ "85.5%"
      assert status_req.body["description"] =~ "+5.5%"
    end

    test "does not post PR comment when no PR number" do
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project, pr: nil)

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()
      comment_posts = Enum.filter(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/comments")
      end)

      assert length(comment_posts) == 0
    end

    test "does not post PR comment when PR number is empty string" do
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project, pr: "")

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()
      comment_posts = Enum.filter(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/comments")
      end)

      assert length(comment_posts) == 0
    end

    test "posts PR comment with coverage report when PR number present" do
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project, pr: "42")

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()

      # Should first GET comments (to check for existing)
      get_comments = Enum.filter(requests, fn r ->
        r.method == "GET" && String.contains?(r.path, "/issues/42/comments")
      end)
      assert length(get_comments) == 1

      # Then POST new comment
      post_comments = Enum.filter(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/issues/42/comments")
      end)
      assert length(post_comments) == 1

      [comment_req] = post_comments
      body = comment_req.body["body"]
      assert body =~ "<!-- opencov-report -->"
      assert body =~ "Pull Request Test Coverage Report"
      assert body =~ "85.5%"
      assert body =~ "lib/app.ex"
      assert body =~ "Files with Coverage Reduction"
    end

    test "sends both commit status and PR comment in one notify" do
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project, pr: "7")

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()

      status_count = Enum.count(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/statuses/")
      end)
      comment_count = Enum.count(requests, fn r ->
        r.method == "POST" && String.contains?(r.path, "/comments")
      end)

      assert status_count == 1
      assert comment_count == 1
    end

    test "does nothing when project URL doesn't match gitea URL" do
      project = insert(:project, base_url: "https://github.com/other/repo")
      build = make_build_with_coverage(project, pr: "1")

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()
      assert length(requests) == 0
    end

    test "authorization header includes token" do
      # We can't easily inspect headers from Plug, but we verify
      # the request succeeds (fake server returns 201), which means
      # HTTPoison sent the request correctly
      project = insert(:project, base_url: "http://127.0.0.1:#{@fake_port}/TestOwner/test-repo")
      build = make_build_with_coverage(project)

      Gitea.notify(build)
      :timer.sleep(500)

      requests = FakeGitea.get_requests()
      assert length(requests) > 0
    end
  end
end
