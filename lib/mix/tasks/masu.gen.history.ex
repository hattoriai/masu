defmodule Mix.Tasks.Masu.Gen.History do
  @shortdoc "Writes the migration of the table of Masu.History.Ecto"

  @moduledoc """
  Writes the migration of the table where `Masu.History.Ecto` keeps the
  history of grids' cells, for the repo that keeps it (the app's own, or
  another: `--migrations-path priv/history_repo/migrations`).

      $ mix masu.gen.history
      $ mix masu.gen.history --table grid_history --migrations-path priv/other_repo/migrations

  Then run `mix ecto.migrate`.

  ## Options

    * `--table` - the table's name, `masu_history` unless given (pass the
      same `table` to `use Masu.History.Ecto`).
    * `--migrations-path` - where to write it, `priv/repo/migrations`
      unless given.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _args} =
      OptionParser.parse!(argv, strict: [table: :string, migrations_path: :string])

    table = Keyword.get(opts, :table, "masu_history")
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

      # The history of Masu grids (Masu.History.Ecto): each change of a
      # cell (key) or of a row (key is nil), who made it, and when; data
      # has the row's id and the values before and after.
      def change do
        create table(:#{table}) do
          add :grid, :string, null: false
          add :row, :string, null: false
          add :key, :string
          add :op, :string, null: false
          add :user_id, :string
          add :user_name, :string
          add :origin, :string
          add :batch, :string
          add :data, :map, null: false
          add :inserted_at, :utc_datetime_usec, null: false
        end

        create index(:#{table}, [:grid, :row, :key])
        create index(:#{table}, [:grid, :inserted_at])
        create index(:#{table}, [:batch])
      end
    end
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
