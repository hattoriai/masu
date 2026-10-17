defmodule Mix.Tasks.Masu.Gen.ViewsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Masu.Gen.Views

  @moduletag :tmp_dir

  test "writes the migration of the table, once", %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    path = Views.write(dir, "masu_views", :my_app, "20261017000000")

    assert Path.basename(path) == "20261017000000_create_masu_views.exs"
    source = File.read!(path)
    assert source =~ "defmodule MyApp.Repo.Migrations.CreateMasuViews do"
    assert source =~ "create table(:masu_views) do"
    assert source =~ "add :params, :map, null: false"
    assert {_quoted, []} = {Code.string_to_quoted!(source), []}

    assert_raise Mix.Error, ~r/a migration of masu_views exists/, fn ->
      Views.write(dir, "masu_views", :my_app, "20261018000000")
    end
  end

  test "takes a table of another name, not any text", %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    assert Views.write(dir, "grid_views", :my_app, "1") =~ "1_create_grid_views.exs"
    assert_raise Mix.Error, fn -> Views.write(dir, "drop table; --", :my_app, "2") end
  end
end
