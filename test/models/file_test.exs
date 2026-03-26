defmodule Opencov.FileTest do
  use Opencov.ModelCase

  alias Opencov.File

  test "for_job" do
    build = insert(:build)
    job = insert(:job, build: build)
    other_job = insert(:job, build: build)
    file = insert(:file, job: job)
    other_file = insert(:file, job: other_job)

    files_ids = Opencov.Repo.all(File.for_job(job)) |> Enum.map(fn f -> f.id end)
    other_files_ids = Opencov.Repo.all(File.for_job(other_job)) |> Enum.map(fn f -> f.id end)

    assert files_ids == [file.id]
    assert other_files_ids == [other_file.id]
  end

  test "for_job with list of jobs" do
    build = insert(:build)
    job1 = insert(:job, build: build)
    job2 = insert(:job, build: build)
    file1 = insert(:file, job: job1)
    file2 = insert(:file, job: job2)

    files = File.for_job([job1.id, job2.id]) |> Repo.all
    ids = Enum.map(files, & &1.id)
    assert file1.id in ids
    assert file2.id in ids
  end

  test "with_name" do
    job = insert(:job)
    file = insert(:file, job: job, name: "target.py")
    insert(:file, job: job, name: "other.py")

    found = File |> File.with_name("target.py") |> Repo.all
    assert length(found) == 1
    assert hd(found).id == file.id
  end

  test "covered and unperfect filters" do
    insert(:file, coverage_lines: [0, 0])
    insert(:file, coverage_lines: [100, 100])
    normal = insert(:file, coverage_lines: [50, 100, 0])
    normal_only = File |> File.with_filters(["unperfect", "covered"]) |> Opencov.Repo.all
    assert Enum.count(normal_only) == 1
    assert List.first(normal_only).id == normal.id
  end

  test "changed and cov_changed filters" do
    previous_file = insert(:file, source: "print 'hello'", coverage_lines: [0, 100]) |> Repo.preload(:job)
    file = insert(:file, coverage_lines: [0, 100], job: previous_file.job)
    cov_changed = File |> File.with_filters(["cov_changed"]) |> Opencov.Repo.all
    changed = File |> File.with_filters(["changed"]) |> Opencov.Repo.all
    refute file.id in Enum.map(cov_changed, &(&1.id))
    assert file.id in Enum.map(changed, &(&1.id))
  end

  test "unknown filter is a no-op" do
    file = insert(:file, coverage_lines: [1])
    result = File |> File.with_filters(["nonexistent_filter"]) |> Repo.all
    assert file.id in Enum.map(result, & &1.id)
  end

  # --- coverage computation ---

  test "compute_coverage with mixed lines" do
    assert File.compute_coverage([0, 1, nil, 0, 2, 1]) == 60.0
  end

  test "compute_coverage with empty list" do
    assert File.compute_coverage([]) == 0.0
  end

  test "compute_coverage with all nil" do
    assert File.compute_coverage([nil, nil]) == 0.0
  end

  test "compute_coverage with all covered" do
    assert File.compute_coverage([1, 5, 3]) == 100.0
  end

  test "compute_coverage with none covered" do
    assert File.compute_coverage([0, 0, 0]) == 0.0
  end

  test "relevant_lines_count excludes nil" do
    assert File.relevant_lines_count([nil, 0, 1, nil, 2]) == 3
  end

  test "covered_lines_count excludes nil and zero" do
    assert File.covered_lines_count([nil, 0, 1, nil, 2, 0]) == 2
  end

  # --- sort ---

  test "sort_by name asc" do
    job = insert(:job)
    insert(:file, job: job, name: "b.py", coverage_lines: [1])
    insert(:file, job: job, name: "a.py", coverage_lines: [1])
    files = File |> File.for_job(job) |> File.sort_by("name", "asc") |> Repo.all
    assert hd(files).name == "a.py"
  end

  test "sort_by coverage desc" do
    job = insert(:job)
    insert(:file, job: job, name: "low.py", coverage_lines: [0, 1])
    insert(:file, job: job, name: "high.py", coverage_lines: [1, 1])
    files = File |> File.for_job(job) |> File.sort_by("coverage", "desc") |> Repo.all
    assert hd(files).name == "low.py"
  end

  # --- JSON encoding ---

  test "jason encoder includes name, source, coverage" do
    file = insert(:file, name: "test.py", source: "x = 1", coverage_lines: [1])
    encoded = Jason.encode!(file)
    decoded = Jason.decode!(encoded)
    assert decoded["name"] == "test.py"
    assert decoded["source"] == "x = 1"
    assert decoded["coverage"] == [1]
  end
end
