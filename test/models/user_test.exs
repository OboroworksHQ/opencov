defmodule Opencov.UserTest do
  use Opencov.ModelCase

  alias Opencov.UserManager

  test "changeset with valid attributes" do
    changeset = UserManager.changeset(%Opencov.User{}, params_for(:user))
    assert changeset.valid?
  end

  test "changeset requires email" do
    changeset = UserManager.changeset(%Opencov.User{}, %{name: "test", password: "secret"})
    refute changeset.valid?
  end

  test "changeset requires name" do
    changeset = UserManager.changeset(%Opencov.User{}, %{email: "a@b.com", password: "secret"})
    refute changeset.valid?
  end

  test "password_update_changeset rejects short passwords" do
    user = insert(:user) |> confirmed_user |> with_secure_password("oldpassword")
    changeset = UserManager.password_update_changeset(user, %{
      current_password: "oldpassword",
      password: "short"
    })
    refute changeset.valid?
  end
end
