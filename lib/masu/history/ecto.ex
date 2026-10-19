if Code.ensure_loaded?(Ecto.Query) do
  defmodule Masu.History.Ecto do
    @moduledoc """
    The history of grids in a table of any Ecto repo (see `Masu.History`):
    the grid's own, or one of its own, in another database.

        defmodule MyApp.GridHistory do
          use Masu.History.Ecto, repo: MyApp.Repo
        end

        # In a SQLite file of its own, next to the app's PostgreSQL:
        defmodule MyApp.GridHistory do
          use Masu.History.Ecto, repo: MyApp.HistoryRepo
        end

        <.data_grid id="orders" ... history={MyApp.GridHistory} user={@user}>

    `mix masu.gen.history` writes the migration of the table,
    `masu_history` (`--migrations-path` for another repo's). Options of
    `use`: `repo` (required), and `table`, for a table of another name.

    An entry is a row: `grid`, `row` (the row's id, as text), `key` (nil
    for a row's own entry), `op`, `user_id`, `user_name`, `origin`,
    `batch`, `data` (a map: the row's id, and the values before and
    after) and `inserted_at`. The table has indexes on `grid` with `row`
    and `key`, and on `batch`. It runs on PostgreSQL, MySQL and SQLite.
    """

    defmodule Record do
      @moduledoc false
      use Ecto.Schema

      schema "masu_history" do
        field(:grid, :string)
        field(:row, :string)
        field(:key, :string)
        field(:op, :string)
        field(:user_id, :string)
        field(:user_name, :string)
        field(:origin, :string)
        field(:batch, :string)
        field(:data, :map)
        field(:inserted_at, :utc_datetime_usec)
      end
    end

    import Ecto.Query

    alias Masu.History.Entry

    @doc false
    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)
      table = Keyword.get(opts, :table, "masu_history")
      store = __MODULE__

      quote do
        @behaviour Masu.History

        @impl true
        def record(entries), do: unquote(store).record(unquote(repo), unquote(table), entries)

        @impl true
        def for_cell(grid, row_id, key, opts \\ []),
          do: unquote(store).for_cell(unquote(repo), unquote(table), grid, row_id, key, opts)

        @impl true
        def for_row(grid, row_id, opts \\ []),
          do: unquote(store).for_row(unquote(repo), unquote(table), grid, row_id, opts)

        @impl true
        def recent(grid, opts \\ []),
          do: unquote(store).recent(unquote(repo), unquote(table), grid, opts)

        @impl true
        def batch(grid, batch),
          do: unquote(store).batch(unquote(repo), unquote(table), grid, batch)

        @impl true
        def entry(grid, id), do: unquote(store).entry(unquote(repo), unquote(table), grid, id)

        @impl true
        def repo, do: unquote(repo)
      end
    end

    @doc false
    def record(_repo, _table, []), do: :ok

    def record(repo, table, entries) do
      rows =
        for %Entry{} = entry <- entries do
          %{
            grid: entry.grid,
            row: to_string(entry.row_id),
            key: entry.key,
            op: Atom.to_string(entry.op),
            user_id: entry.user_id,
            user_name: entry.user_name,
            origin: Atom.to_string(entry.origin),
            batch: entry.batch,
            data: %{"id" => entry.row_id, "before" => entry.before, "after" => entry.after},
            inserted_at: entry.at
          }
        end

      # Through the schema, so that each adapter dumps the map its way.
      rows
      |> Enum.chunk_every(500)
      |> Enum.each(&repo.insert_all({table, Record}, &1))

      :ok
    end

    @doc false
    def for_cell(repo, table, grid, row_id, key, opts) do
      row = to_string(row_id)

      from(h in {table, Record}, where: h.grid == ^grid and h.row == ^row and h.key == ^key)
      |> newest(repo, opts)
    end

    @doc false
    def for_row(repo, table, grid, row_id, opts) do
      row = to_string(row_id)
      from(h in {table, Record}, where: h.grid == ^grid and h.row == ^row) |> newest(repo, opts)
    end

    @doc false
    def recent(repo, table, grid, opts),
      do: from(h in {table, Record}, where: h.grid == ^grid) |> newest(repo, opts)

    @doc false
    def batch(repo, table, grid, batch) do
      from(h in {table, Record},
        where: h.grid == ^grid and h.batch == ^batch,
        order_by: [asc: h.id]
      )
      |> repo.all()
      |> Enum.map(&entry/1)
    end

    @doc false
    def entry(repo, table, grid, id) do
      case Integer.parse(to_string(id)) do
        {id, ""} ->
          from(h in {table, Record}, where: h.grid == ^grid and h.id == ^id)
          |> repo.one()
          |> then(&(&1 && entry(&1)))

        _other ->
          nil
      end
    end

    defp newest(query, repo, opts) do
      query
      |> order_by([h], desc: h.inserted_at, desc: h.id)
      |> limit(^Keyword.get(opts, :limit, 50))
      |> repo.all()
      |> Enum.map(&entry/1)
    end

    defp entry(%Record{} = record) do
      %Entry{
        id: Integer.to_string(record.id),
        grid: record.grid,
        row_id: Map.get(record.data, "id", record.row),
        key: record.key,
        op: op(record.op),
        before: Map.get(record.data, "before"),
        after: Map.get(record.data, "after"),
        user_id: record.user_id,
        user_name: record.user_name,
        origin: origin(record.origin),
        batch: record.batch,
        at: record.inserted_at
      }
    end

    defp op("create"), do: :create
    defp op("delete"), do: :delete
    defp op(_update), do: :update

    # An origin of Masu.Write's, or an app's own (`record/2`), as an atom
    # that exists: an unknown one reads as `:other`.
    defp origin(nil), do: :other

    defp origin(name) do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> :other
    end
  end
end
