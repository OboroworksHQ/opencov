defmodule Opencov.Repo.Migrations.MakeFileSourceNullable do
  use Ecto.Migration

  def change do
    alter table(:files) do
      modify :source, :text, null: true, default: "(no source)"
    end
  end
end
