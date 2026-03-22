defmodule Opencov.Integrations.GiteaTest do
  use ExUnit.Case, async: true

  alias Opencov.Integrations.Gitea

  # --- parse_repo ---

  describe "parse_repo/2" do
    test "extracts owner and repo from matching gitea URL" do
      assert {:ok, "Oboroworks", "micelio"} =
        Gitea.parse_repo("https://git.oboroworks.com/Oboroworks/micelio", "https://git.oboroworks.com")
    end

    test "handles .git suffix" do
      assert {:ok, "Oboroworks", "micelio"} =
        Gitea.parse_repo("https://git.oboroworks.com/Oboroworks/micelio.git", "https://git.oboroworks.com")
    end

    test "handles trailing slash" do
      assert {:ok, "Oboroworks", "micelio"} =
        Gitea.parse_repo("https://git.oboroworks.com/Oboroworks/micelio/", "https://git.oboroworks.com")
    end

    test "handles extra path segments" do
      assert {:ok, "Oboroworks", "micelio"} =
        Gitea.parse_repo("https://git.oboroworks.com/Oboroworks/micelio/src/main", "https://git.oboroworks.com")
    end

    test "returns error when hosts don't match" do
      assert :error =
        Gitea.parse_repo("https://github.com/user/repo", "https://git.oboroworks.com")
    end

    test "returns error when path has no repo" do
      assert :error =
        Gitea.parse_repo("https://git.oboroworks.com/", "https://git.oboroworks.com")
    end

    test "returns error when path has only owner" do
      assert :error =
        Gitea.parse_repo("https://git.oboroworks.com/Oboroworks", "https://git.oboroworks.com")
    end

    test "returns error for nil base_url" do
      assert :error = Gitea.parse_repo(nil, "https://git.oboroworks.com")
    end

    test "returns error for nil gitea_url" do
      assert :error = Gitea.parse_repo("https://git.oboroworks.com/a/b", nil)
    end

    test "returns error for empty strings" do
      assert :error = Gitea.parse_repo("", "")
    end
  end

  # --- format_pct ---

  describe "format_pct/1" do
    test "formats nil as 0%" do
      assert Gitea.format_pct(nil) == "0%"
    end

    test "formats zero" do
      assert Gitea.format_pct(0.0) == "0.0%"
    end

    test "formats integer-like float" do
      assert Gitea.format_pct(85.0) == "85.0%"
    end

    test "formats with decimals" do
      assert Gitea.format_pct(82.771) == "82.77%"
    end

    test "rounds to 2 decimal places" do
      assert Gitea.format_pct(85.555) == "85.56%"
    end

    test "formats 100%" do
      assert Gitea.format_pct(100.0) == "100.0%"
    end
  end

  # --- format_delta ---

  describe "format_delta/1" do
    test "returns empty string when no previous coverage" do
      build = %{coverage: 85.0, previous_coverage: nil}
      assert Gitea.format_delta(build) == ""
    end

    test "formats positive delta with plus sign" do
      build = %{coverage: 85.0, previous_coverage: 80.0}
      assert Gitea.format_delta(build) == "+5.0%"
    end

    test "formats negative delta" do
      build = %{coverage: 80.0, previous_coverage: 85.0}
      assert Gitea.format_delta(build) == "-5.0%"
    end

    test "formats zero delta" do
      build = %{coverage: 85.0, previous_coverage: 85.0}
      assert Gitea.format_delta(build) == "+0.0%"
    end

    test "rounds to 1 decimal" do
      build = %{coverage: 85.55, previous_coverage: 80.11}
      assert Gitea.format_delta(build) == "+5.4%"
    end
  end

  # --- delta_direction ---

  describe "delta_direction/1" do
    test "returns 'increased' when coverage went up" do
      build = %{coverage: 90.0, previous_coverage: 80.0}
      assert Gitea.delta_direction(build) == "increased"
    end

    test "returns 'decreased' when coverage went down" do
      build = %{coverage: 70.0, previous_coverage: 80.0}
      assert Gitea.delta_direction(build) == "decreased"
    end

    test "returns 'increased' when coverage unchanged" do
      build = %{coverage: 80.0, previous_coverage: 80.0}
      assert Gitea.delta_direction(build) == "increased"
    end

    test "returns 'is' when no previous coverage" do
      build = %{coverage: 80.0, previous_coverage: nil}
      assert Gitea.delta_direction(build) == "is"
    end
  end

  # --- format_pr_comment ---

  describe "format_pr_comment/1" do
    test "returns no-data message when build has no files" do
      build = %{
        build_number: 1,
        id: 1,
        coverage: 0.0,
        previous_coverage: nil,
        previous_build: nil,
        previous_build_id: nil,
        jobs: []
      }
      result = Gitea.format_pr_comment(build)
      assert result =~ "No coverage data available"
      assert result =~ "Build 1"
    end

    test "generates full report with files" do
      build = %{
        build_number: 5,
        id: 42,
        coverage: 85.5,
        previous_coverage: 80.0,
        previous_build: %{build_number: 4},
        previous_build_id: 41,
        jobs: [
          %{files: [
            %Opencov.File{
              name: "lib/app.ex",
              coverage: 90.0,
              previous_coverage: 95.0,
              coverage_lines: [1, 1, 0, nil, 1, 1, 1, 1, 1, 1]
            },
            %Opencov.File{
              name: "lib/new.ex",
              coverage: 80.0,
              previous_coverage: nil,
              coverage_lines: [1, 1, 1, 1, 0, nil, nil]
            }
          ]}
        ]
      }

      result = Gitea.format_pr_comment(build)

      # Header
      assert result =~ "Pull Request Test Coverage Report for [Build 5]"

      # Details section
      assert result =~ "changed or added relevant lines"
      assert result =~ "files lost coverage"
      assert result =~ "85.5%"

      # Files with reduction table
      assert result =~ "lib/app.ex"
      assert result =~ "Files with Coverage Reduction"

      # Totals
      assert result =~ "coverage-86%25"  # badge
      assert result =~ "Build 4"  # previous build
      assert result =~ "+5.5%"  # delta

      # Should NOT include new file in reduction table
      refute result =~ "lib/new.ex" |> String.replace("/", "") |> then(fn _ ->
        # new.ex has no previous_coverage so shouldn't be in reduction table
        result =~ "| [lib/new.ex]"
      end)
    end

    test "handles build with no previous build" do
      build = %{
        build_number: 1,
        id: 1,
        coverage: 75.0,
        previous_coverage: nil,
        previous_build: nil,
        previous_build_id: nil,
        jobs: [
          %{files: [
            %Opencov.File{
              name: "lib/app.ex",
              coverage: 75.0,
              previous_coverage: nil,
              coverage_lines: [1, 1, 1, 0]
            }
          ]}
        ]
      }

      result = Gitea.format_pr_comment(build)
      assert result =~ "Build 1"
      assert result =~ "75.0%"
      assert result =~ "N/A"  # no previous build
      assert result =~ "is"   # delta_direction with no previous
    end

    test "badge color is red for low coverage" do
      build = %{
        build_number: 1, id: 1, coverage: 20.0,
        previous_coverage: nil, previous_build: nil, previous_build_id: nil,
        jobs: [%{files: [%Opencov.File{name: "a.ex", coverage: 20.0, previous_coverage: nil, coverage_lines: [1, 0, 0, 0, 0]}]}]
      }
      assert Gitea.format_pr_comment(build) =~ "red"
    end

    test "badge color is brightgreen for high coverage" do
      build = %{
        build_number: 1, id: 1, coverage: 95.0,
        previous_coverage: nil, previous_build: nil, previous_build_id: nil,
        jobs: [%{files: [%Opencov.File{name: "a.ex", coverage: 95.0, previous_coverage: nil, coverage_lines: [1, 1, 1, 1, 1]}]}]
      }
      assert Gitea.format_pr_comment(build) =~ "brightgreen"
    end

    test "escapes markdown in filenames with brackets" do
      build = %{
        build_number: 1, id: 1, coverage: 50.0,
        previous_coverage: 60.0, previous_build: %{build_number: 0}, previous_build_id: 0,
        jobs: [%{files: [
          %Opencov.File{
            name: "test]file.ex",
            coverage: 50.0,
            previous_coverage: 60.0,
            coverage_lines: [1, 0, nil]
          }
        ]}]
      }
      result = Gitea.format_pr_comment(build)
      assert result =~ "test\\]file.ex"
    end
  end

  # --- notify (integration-level) ---

  describe "notify/1" do
    test "does nothing when gitea is not configured" do
      # Ensure env vars are not set
      System.delete_env("GITEA_ENABLED")
      System.delete_env("GITEA_URL")
      System.delete_env("GITEA_TOKEN")
      Application.put_env(:opencov, :gitea, [])

      build = %Opencov.Build{id: 1}
      # Should return nil (no task started)
      assert Gitea.notify(build) == nil
    end
  end
end
