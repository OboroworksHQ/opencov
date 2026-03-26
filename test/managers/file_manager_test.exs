defmodule Opencov.FileManagerTest do
  use Opencov.ModelCase

  alias Opencov.File
  alias Opencov.FileManager

  @coverage_lines [0, nil, 3, nil, 0, 1]

  test "changeset with valid attributes" do
    changeset = FileManager.changeset(%File{}, Map.put(params_for(:file), :job_id, 1))
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = FileManager.changeset(%File{}, %{})
    refute changeset.valid?
  end

  test "changeset requires name" do
    changeset = FileManager.changeset(%File{}, %{"coverage_lines" => [1, 0], "source" => "x"})
    refute changeset.valid?
    assert {:name, _} = List.keyfind(changeset.errors, :name, 0)
  end

  test "empty coverage" do
    file = insert(:file, coverage_lines: [])
    assert file.coverage == 0
  end

  test "normal coverage" do
    file = insert(:file, coverage_lines: @coverage_lines)
    assert file.coverage == 50
  end

  test "full coverage" do
    file = insert(:file, coverage_lines: [1, 2, 3])
    assert file.coverage == 100.0
  end

  test "zero coverage" do
    file = insert(:file, coverage_lines: [0, 0, 0])
    assert file.coverage == 0.0
  end

  test "all nil coverage lines" do
    file = insert(:file, coverage_lines: [nil, nil, nil])
    assert file.coverage == 0
  end

  # --- source handling (covers the NOT NULL bug fix) ---

  test "changeset without source defaults to (no source)" do
    params = %{"name" => "test.py", "coverage" => [1, 0, nil]}
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :source) == "(no source)"
  end

  test "changeset with explicit nil source defaults to (no source)" do
    params = %{"name" => "test.py", "source" => nil, "coverage" => [1, 0]}
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :source) == "(no source)"
  end

  test "changeset with empty string source defaults to (no source)" do
    params = %{"name" => "test.py", "source" => "", "coverage" => [1]}
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :source) == "(no source)"
  end

  test "changeset preserves provided source" do
    params = %{"name" => "test.py", "source" => "print('hello')", "coverage" => [1]}
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :source) == "print('hello')"
  end

  test "insert file without source succeeds" do
    file = insert(:file, source: nil, coverage_lines: [0, 1])
    assert file.id
  end

  test "insert file with empty coverage and no source succeeds" do
    file = insert(:file, source: nil, coverage_lines: [])
    assert file.id
    assert file.coverage == 0
  end

  # --- coveralls-compatible payload formats ---

  test "coveralls payload with source_digest but no source" do
    params = %{
      "name" => "agent/events/__init__.py",
      "source_digest" => "d41d8cd98f00b204e9800998ecf8427e",
      "coverage" => []
    }
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
  end

  test "coveralls payload with coverage as list of nil" do
    params = %{
      "name" => "empty_module.py",
      "coverage" => [nil, nil, nil]
    }
    changeset = FileManager.changeset(%File{}, Map.put(params, "job_id", 1))
    assert changeset.valid?
  end

  # --- previous file tracking ---

  test "set_previous_file when a previous file exists" do
    project = insert(:project)
    previous_job = insert(:job, job_number: 1, build: insert(:build, project: project, build_number: 1))
    job = insert(:job, job_number: 1, build: insert(:build, project: project, build_number: 2))
    assert job.previous_job_id == previous_job.id

    previous_file = insert(:file, job: previous_job, name: "file")
    file = insert(:file, job: job, name: "file")
    assert file.previous_file_id == previous_file.id
    assert file.previous_coverage == previous_file.coverage
  end

  test "set_previous_file when no previous file exists" do
    file = insert(:file, name: "brand_new.py")
    assert file.previous_file_id == nil
    assert file.previous_coverage == nil
  end
end
