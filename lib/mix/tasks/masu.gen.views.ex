defmodule Mix.Tasks.Masu.Gen.Views do
  @shortdoc "Writes the migration of the table of Masu.Views.Ecto"

  @moduledoc """
  Writes the migration of the table where `Masu.Views.Ecto` keeps
  people's views of grids.

      $ mix masu.gen.views
      $ mix masu.gen.views --table grid_views --migrations-path priv/other_repo/migrations

  Then run `mix ecto.migrate`.

  ## Options

    * `--table` - the table's name, `masu_views` unless given (pass the
      same `table` to `use Masu.Views.Ecto`).
    * `--migrations-path` - where to write it, `priv/repo/migrations`
      unless given.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _args} =
      OptionParser.parse!(argv, strict: [table: :string, migrations_path: :string])

    table = Keyword.get(opts, :table, "masu_views")
    dir = Keyword.get(opts, :migrations_path, "priv/repo/migrations")
    write(dir, table, Mix.Project.config()[:app], timestamp())
  end

  @doc false
  # Writes the migration to `dir`, and returns its path.
  @spec write(Path.t(), String.t(), atom(), String.t()) :: Path.t()
  def write(dir, table, app, timestamp) do
    unless table =~ ~r/^[a-z_][a-z0-9_]*$/ do
      Mix.raise("a table's name is lowercase letters, digits and underscores, got: #{table}")
    end

    existing = Path.wildcard(Path.join(dir, "*_create_#{table}.exs"))
    if existing != [], do: Mix.raise("a migration of #{table} exists: #{hd(existing)}")

    path = Path.join(dir, "#{timestamp}_create_#{table}.exs")
    File.mkdir_p!(dir)
    File.write!(path, migration(app, table))
    Mix.shell().info("* creating #{path}")
    path
  end

  @doc false
  @spec migration(atom(), String.t()) :: String.t()
  def migration(app, table) do
    app_module = app |> to_string() |> Macro.camelize()
    name = Macro.camelize("create_#{table}")

    """
    defmodule #{app_module}.Repo.Migrations.#{name} do
      use Ecto.Migration

      # The views of Masu grids (Masu.Views.Ecto): each person's last view
      # of a grid (name is nil), and the views they named.
      def change do
        create table(:#{table}) do
          add :grid, :string, null: false
          add :owner, :string, null: false
          add :name, :string
          add :shared, :boolean, null: false, default: false
          add :params, :map, null: false
          timestamps(type: :utc_datetime)
        end

        create index(:#{table}, [:grid, :owner])
        create index(:#{table}, [:grid, :shared])
      end
    end
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
