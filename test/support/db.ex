defmodule MasuTest.DB do
  @moduledoc """
  The database of the Ecto source tests, by MASU_DB: SQLite in a file of
  the run's own (the default), or PostgreSQL or MySQL at MASU_DB_URL
  (docker-compose.yml's by default). The history's repo of its own has
  the database of the same name and `_history`.
  """

  @urls %{
    Ecto.Adapters.Postgres => "ecto://postgres:postgres@localhost:5432/masu_test",
    Ecto.Adapters.MyXQL => "ecto://root:mysql@localhost:3306/masu_test"
  }

  @adapters %{
    "sqlite" => Ecto.Adapters.SQLite3,
    "postgres" => Ecto.Adapters.Postgres,
    "mysql" => Ecto.Adapters.MyXQL
  }

  @doc """
  The adapter of MASU_DB. The test repos compile with it, and again when
  it changes (their `__mix_recompile__?/0`).
  """
  def adapter, do: Map.fetch!(@adapters, System.get_env("MASU_DB", "sqlite"))

  @doc "Starts a repo on an empty database, its name with `suffix`."
  def start!(repo, suffix \\ "") do
    {:ok, _pid} = repo.start_link(options(adapter(), suffix))
    :ok
  end

  defp options(Ecto.Adapters.SQLite3, suffix) do
    # A file of this run's own, deleted before and after it: an earlier
    # run's file must not give its tables to this one.
    path = Path.join(System.tmp_dir!(), "masu-test#{suffix}-#{System.pid()}.db")
    File.rm(path)
    System.at_exit(fn _status -> File.rm(path) end)
    [database: path, pool_size: 1]
  end

  defp options(adapter, suffix) do
    # The database again, empty: an earlier run's tables go with it.
    options =
      System.get_env("MASU_DB_URL", Map.fetch!(@urls, adapter))
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.update!(:database, &(&1 <> suffix))
      # Two at least: a migration holds a lock on one.
      |> Keyword.put(:pool_size, 5)
      |> Keyword.merge(collation(adapter))

    _ = adapter.storage_down(options)
    :ok = adapter.storage_up(options)
    options
  end

  # PostgreSQL sorts text by bytes, as SQLite does, whatever the server's
  # locale. MySQL keeps its own collation, which ignores case.
  defp collation(Ecto.Adapters.Postgres),
    do: [template: "template0", lc_collate: "C", lc_ctype: "C", encoding: "UTF8"]

  defp collation(_adapter), do: []

  @doc """
  Runs the migration that a `mix masu.gen.*` task writes, in a repo, as
  `version`: each of a repo's migrations has its own.
  """
  def generated!(repo, task, table, version) do
    dir = Path.join(System.tmp_dir!(), "masu-#{table}-#{System.pid()}-#{inspect(repo)}")
    File.rm_rf!(dir)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)
    task.write(dir, table, :masu_test, version)
    Mix.shell(shell)
    # The same migration's module, for each repo.
    Code.put_compiler_option(:ignore_module_conflict, true)
    Ecto.Migrator.run(repo, dir, :up, all: true, log: false)
    Code.put_compiler_option(:ignore_module_conflict, false)
    File.rm_rf!(dir)
    :ok
  end

  @doc """
  The next id of a table is the one after its largest, as in SQLite: rows
  inserted with their own ids do not move a sequence of PostgreSQL, and a
  deleted row's id stays taken in MySQL.
  """
  def reset_ids!(repo, table) do
    case adapter() do
      Ecto.Adapters.SQLite3 ->
        :ok

      Ecto.Adapters.Postgres ->
        repo.query!(
          "SELECT setval(pg_get_serial_sequence('#{table}', 'id'), " <>
            "COALESCE((SELECT max(id) FROM #{table}), 0) + 1, false)"
        )

      Ecto.Adapters.MyXQL ->
        # MySQL moves it to the largest id and one, at least.
        repo.query!("ALTER TABLE #{table} AUTO_INCREMENT = 1")
    end

    :ok
  end
end

defmodule MasuTest.Tables do
  @moduledoc "The tables of the tests, in the repo's own types."
  use Ecto.Migration

  def change do
    # MySQL's DECIMAL has no fraction unless it has a scale.
    decimal =
      if MasuTest.DB.adapter() == Ecto.Adapters.MyXQL, do: [precision: 12, scale: 2], else: []

    create table(:orders) do
      add(:number, :text)
      add(:customer, :text)
      add(:status, :text)
      add(:total, :decimal, decimal)
      add(:placed_on, :date)
    end

    # Tasks that a grid adds and deletes (Masu.Edit), of their own.
    create table(:tasks) do
      add(:title, :text, null: false)
      add(:status, :text)
      add(:points, :decimal, decimal)
    end

    # A ledger whose changes the history keeps (Masu.History), of its own.
    create table(:ledger) do
      add(:item, :text)
      add(:amount, :integer)
    end

    # Chores that the actions of a grid change (Masu.Action), of their own.
    create table(:chores) do
      add(:title, :text)
      add(:done, :boolean)
    end

    # Items with empty values and repeated ones, for paging by key.
    create table(:items) do
      add(:name, :text)
      add(:score, :integer)
    end

    # The chart of accounts of the tree tests.
    create table(:accounts) do
      add(:parent_id, :integer)
      add(:name, :text)
      add(:balance, :decimal, decimal)
    end

    # Sales of customers of companies, with tags and lines.
    create table(:companies) do
      add(:name, :text)
      add(:country, :text)
      add(:size, :text)
    end

    create table(:customers) do
      add(:name, :text)
      add(:company_id, :integer)
    end

    create table(:sales) do
      add(:number, :text)
      add(:amount, :integer)
      add(:customer_id, :integer)
    end

    create table(:tags) do
      add(:name, :text)
    end

    create table(:sale_tags, primary_key: false) do
      add(:sale_id, :integer)
      add(:tag_id, :integer)
    end

    create table(:sale_lines) do
      add(:product, :text)
      add(:sale_id, :integer)
    end
  end
end
