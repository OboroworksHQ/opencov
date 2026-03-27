defmodule Opencov.Integrations.GithubTest do
  use ExUnit.Case, async: true

  alias Opencov.Integrations.Github

  # --- parse_repo ---

  describe "parse_repo/1" do
    test "extracts owner and repo from github URL" do
      assert {:ok, "OboroworksHQ", "oboroworks-agents"} =
        Github.parse_repo("https://github.com/OboroworksHQ/oboroworks-agents")
    end

    test "handles .git suffix" do
      assert {:ok, "OboroworksHQ", "oboroworks-agents"} =
        Github.parse_repo("https://github.com/OboroworksHQ/oboroworks-agents.git")
    end

    test "handles trailing slash" do
      assert {:ok, "OboroworksHQ", "oboroworks-agents"} =
        Github.parse_repo("https://github.com/OboroworksHQ/oboroworks-agents/")
    end

    test "handles extra path segments" do
      assert {:ok, "OboroworksHQ", "oboroworks-agents"} =
        Github.parse_repo("https://github.com/OboroworksHQ/oboroworks-agents/tree/main")
    end

    test "returns error for non-github host" do
      assert :error = Github.parse_repo("https://git.oboroworks.com/Oboroworks/micelio")
    end

    test "returns error when path has no repo" do
      assert :error = Github.parse_repo("https://github.com/")
    end

    test "returns error when path has only owner" do
      assert :error = Github.parse_repo("https://github.com/OboroworksHQ")
    end

    test "returns error for nil" do
      assert :error = Github.parse_repo(nil)
    end

    test "returns error for empty string" do
      assert :error = Github.parse_repo("")
    end
  end
end
