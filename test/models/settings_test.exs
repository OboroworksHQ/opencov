defmodule Opencov.SettingsTest do
  use Opencov.ModelCase

  alias Opencov.SettingsManager

  test "changeset with valid attributes" do
    changeset = SettingsManager.changeset(%Opencov.Settings{}, %{
      signup_enabled: true,
      default_project_visibility: "public"
    })
    assert changeset.valid?
  end

  test "changeset with invalid visibility" do
    changeset = SettingsManager.changeset(%Opencov.Settings{}, %{
      default_project_visibility: "invalid_value"
    })
    refute changeset.valid?
  end

  test "default values" do
    settings = %Opencov.Settings{}
    refute settings.signup_enabled
    assert settings.restricted_signup_domains == ""
  end
end
