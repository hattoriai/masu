defmodule Masu.History do
  @moduledoc ~S"""
  Where a grid keeps the history of its cells: who changed a cell, when,
  from what to what; and a value of the history brought back.

      <.data_grid id="orders" source={Order} repo={Repo} changeset={&Order.changeset/2}
        history={MyApp.GridHistory} user={@user}>

  `history` is a module of this behaviour. Masu has two:

    * `Masu.History.Ecto`, a table of any Ecto repo: the grid's own, or
      another database (`use Masu.History.Ecto, repo: MyApp.HistoryRepo`,
      and `mix masu.gen.history` for its migration);
    * `Masu.History.Memory`, in memory, for development and tests.

  A store of your own implements the callbacks below over what your app
  already keeps (an audit table, PaperTrail, a service).

  ## What is recorded

  Every write of the grid (see `Masu.Write`) that saves: a cell edited,
  pasted, filled, undone or restored is an entry of its cell, with its
  value before and after, as the browser gets them; a new row and a row
  deleted are an entry of the row. The entries of one write (a paste of
  200 cells) share a `batch`. Who is the grid's `user` (`:id` and
  `:name`); when, the time of the record.

  The grid records what its writes save, the grid's own and your
  `on_update`'s alike. What your app changes another way (an action's
  `Repo.update_all`, a job) it records with `record/2`.

  ## In the row's transaction, or after it

  When the store keeps the history in the grid's own repo (`repo/0`),
  the grid's own way of saving (`Masu.Write.save/1`) records a change in
  the transaction that saves it: the change and its record are saved
  together, or neither. In another repo (a SQLite file next to a
  PostgreSQL app, say), no transaction spans both: a change is recorded
  just after it is saved, and a node that stops between the two leaves it
  unrecorded; a change that was not saved is never recorded. Keep the
  history in the main repo when every change must have its record.

  An `on_update` of yours that saves in a transaction of its own records
  in it with `Masu.Write.record/3`.
  """

  alias Masu.{Column, Value}
  alias Masu.History.Entry

  @doc "Keeps entries."
  @callback record(entries :: [Entry.t()]) :: :ok

  @doc "The entries of a cell of the grid, newest first. Options: `:limit`."
  @callback for_cell(grid :: String.t(), row_id :: term(), key :: String.t(), opts :: keyword()) ::
              [Entry.t()]

  @doc "The entries of a row of the grid (of its cells, and of the row), newest first. Options: `:limit`."
  @callback for_row(grid :: String.t(), row_id :: term(), opts :: keyword()) :: [Entry.t()]

  @doc "The latest entries of the grid, newest first. Options: `:limit`."
  @callback recent(grid :: String.t(), opts :: keyword()) :: [Entry.t()]

  @doc "The entries of a batch (one write), as recorded."
  @callback batch(grid :: String.t(), batch :: String.t()) :: [Entry.t()]

  @doc "An entry by its id, or nil."
  @callback entry(grid :: String.t(), id :: String.t()) :: Entry.t() | nil

  @doc """
  The Ecto repo that keeps the entries, or nil: when it is the grid's
  own, the grid records a change in the transaction that saves it.
  """
  @callback repo() :: module() | nil

  @optional_callbacks repo: 0

  defmodule Entry do
    @moduledoc """
    A change of a grid's rows, as `Masu.History` keeps it:

      * `grid` - the grid's id;
      * `row_id` - the row's id, as the browser has it;
      * `key` - the column's key; nil for the row (`op` `:create` or
        `:delete`);
      * `op` - `:update` (a cell), `:create` or `:delete` (a row);
      * `before` and `after` - the cell's value before and after, as the
        browser gets them (`Masu.Wire`); for a row, its cells' values by
        column key;
      * `user_id` and `user_name` - who, from the grid's `user`;
      * `origin` - what they did, as `Masu.Write`'s `origin` says
        (`:edit`, `:paste`, `:restore`...);
      * `batch` - the write it was part of;
      * `at` - when;
      * `id` - the store's id of it.
    """

    @type t :: %__MODULE__{
            id: String.t() | nil,
            grid: String.t(),
            row_id: term(),
            key: String.t() | nil,
            op: :update | :create | :delete,
            before: term(),
            after: term(),
            user_id: String.t() | nil,
            user_name: String.t() | nil,
            origin: atom(),
            batch: String.t() | nil,
            at: DateTime.t()
          }

    defstruct [
      :id,
      :grid,
      :row_id,
      :key,
      :before,
      :after,
      :user_id,
      :user_name,
      :batch,
      :at,
      op: :update,
      origin: :edit
    ]
  end

  @doc """
  Records entries in `store`: what your app changed another way than the
  grid's writes. `fields` of each: `:grid`, `:row_id`, `:key`, `:before`,
  `:after` (as the browser gets them), and `:op`, `:origin`, `:batch`,
  `:user` (a map of `:id` and `:name`), which the entry takes as they are.

      Masu.History.record(MyApp.GridHistory, [
        %{grid: "orders", row_id: order.id, key: "status", before: "paid", after: "archived",
          origin: :archive, user: user}
      ])
  """
  @spec record(module(), [map()]) :: :ok
  def record(store, entries) when is_list(entries) do
    now = DateTime.utc_now()
    store.record(Enum.map(entries, &entry(&1, now)))
  end

  defp entry(%Entry{} = entry, _now), do: entry

  defp entry(fields, now) do
    user = Map.get(fields, :user)

    %Entry{
      grid: Map.fetch!(fields, :grid),
      row_id: Value.to_wire(Map.fetch!(fields, :row_id)),
      key: fields |> Map.get(:key) |> key(),
      op: Map.get(fields, :op, :update),
      before: Map.get(fields, :before),
      after: Map.get(fields, :after),
      user_id: user_id(user),
      user_name: user && Map.get(user, :name),
      origin: Map.get(fields, :origin, :edit),
      batch: Map.get(fields, :batch),
      at: Map.get(fields, :at, now)
    }
  end

  defp key(nil), do: nil
  defp key(key), do: to_string(key)

  defp user_id(nil), do: nil
  defp user_id(%{id: id}), do: to_string(id)
  defp user_id(_user), do: nil

  @doc false
  # The entries of a change of a write that saved, as `row`: a cell's of
  # each column it set, a row's when it was added or deleted.
  @spec entries(map(), atom(), atom(), Masu.Write.Change.t(), term(), [String.t()]) :: [Entry.t()]
  def entries(config, op, origin, change, row, keys) do
    now = DateTime.utc_now()

    base = %Entry{
      grid: config.grid,
      user_id: user_id(config.user),
      user_name: config.user && Map.get(config.user, :name),
      origin: origin,
      batch: config.batch,
      at: now
    }

    case op do
      :update ->
        for key <- keys,
            column = Column.find(config.columns, key),
            before = wire(column, change.row),
            after_value = wire(column, row),
            before != after_value do
          %{base | row_id: change.id, key: key, op: :update, before: before, after: after_value}
        end

      :create ->
        [
          %{
            base
            | row_id: Value.to_wire(config.row_id.(row)),
              op: :create,
              after: cells(config, row)
          }
        ]

      :restore ->
        [
          %{
            base
            | row_id: Value.to_wire(config.row_id.(row)),
              op: :create,
              after: cells(config, row)
          }
        ]

      :delete ->
        [%{base | row_id: change.id, op: :delete, before: cells(config, change.row)}]
    end
  end

  defp wire(column, row), do: column |> Column.get(row) |> Value.to_wire()

  defp cells(config, row) do
    for %Column{field: field} = column <- config.columns, field != nil, into: %{} do
      {column.key, wire(column, row)}
    end
  end

  @doc false
  # The store's repo, for a record in the row's transaction.
  @spec repo(module() | nil) :: module() | nil
  def repo(nil), do: nil

  def repo(store) do
    Code.ensure_loaded(store)
    if function_exported?(store, :repo, 0), do: store.repo()
  end

  @doc false
  # An entry as the browser and Masu.Test get it.
  @spec to_wire(Entry.t()) :: map()
  def to_wire(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "row" => entry.row_id,
      "key" => entry.key,
      "op" => Atom.to_string(entry.op),
      "before" => entry.before,
      "after" => entry.after,
      "user" => entry.user_name,
      "origin" => Atom.to_string(entry.origin),
      "batch" => entry.batch,
      "at" => DateTime.to_iso8601(entry.at)
    }
  end
end

defmodule Masu.History.Memory do
  @moduledoc """
  The history of grids in memory, for development and tests: it lasts as
  long as the node, and every grid of the node shares it. Not for
  production.

  Start it in your supervision tree (or in `test_helper.exs`):

      children = [Masu.History.Memory, ...]
  """
  @behaviour Masu.History

  use Agent

  alias Masu.History.Entry

  @doc false
  def start_link(_opts \\ []), do: Agent.start_link(fn -> {[], 1} end, name: __MODULE__)

  @doc "Forgets every entry."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _state -> {[], 1} end)

  @impl true
  def record(entries) do
    Agent.update(__MODULE__, fn {all, next} ->
      {numbered, next} =
        Enum.map_reduce(entries, next, fn entry, n ->
          {%{entry | id: Integer.to_string(n)}, n + 1}
        end)

      {Enum.reverse(numbered) ++ all, next}
    end)
  end

  @impl true
  def for_cell(grid, row_id, key, opts \\ []),
    do: take(&(&1.grid == grid and same?(&1.row_id, row_id) and &1.key == key), opts)

  @impl true
  def for_row(grid, row_id, opts \\ []),
    do: take(&(&1.grid == grid and same?(&1.row_id, row_id)), opts)

  @impl true
  def recent(grid, opts \\ []), do: take(&(&1.grid == grid), opts)

  @impl true
  def batch(grid, batch),
    do:
      __MODULE__
      |> Agent.get(&elem(&1, 0))
      |> Enum.filter(&(&1.grid == grid and &1.batch == batch))
      |> Enum.reverse()

  @impl true
  def entry(grid, id),
    do:
      __MODULE__
      |> Agent.get(&elem(&1, 0))
      |> Enum.find(&(&1.grid == grid and &1.id == to_string(id)))

  @impl true
  def repo, do: nil

  defp take(fun, opts) do
    __MODULE__
    |> Agent.get(&elem(&1, 0))
    |> Enum.filter(fun)
    |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  defp same?(a, b), do: to_string(a) == to_string(b)

  @doc false
  @spec all() :: [Entry.t()]
  def all, do: Agent.get(__MODULE__, &elem(&1, 0))
end
