defmodule Opencov.ProjectTest do
  use Opencov.ModelCase

  alias Opencov.Project

  test "with_token query" do
    project = insert(:project)
    found = Project |> Project.with_token(project.token) |> Repo.one
    assert found.id == project.id
  end

  test "with_token returns nil for unknown token" do
    refute Project |> Project.with_token("nonexistent") |> Repo.one
  end

  test "visibility_choices" do
    assert "public" in Project.visibility_choices()
    assert "private" in Project.visibility_choices()
    assert "internal" in Project.visibility_choices()
  end
end
