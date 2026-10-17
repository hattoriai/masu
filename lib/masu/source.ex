defmodule Masu.Source do
  @moduledoc """
  Where a grid's rows come from.

  A grid never holds all its rows. It asks its source for the rows of
  its query (`prepare/3`), how many there are (`count/1`), and the rows
  the browser shows (`rows/3`): a block at a time, as the person scrolls.

  Masu has two sources:

    * `Masu.Source.List`, for rows the LiveView already has (`rows={@users}`);
    * `Masu.Source.Ecto`, for an Ecto query or schema
      (`source={User} repo={Repo}`): it sorts, filters, searches and
      counts in the database, and reads only the rows on the screen.

  A source of your own is a module with these callbacks, given as
  `source={{MySource, opts}}`; the grid calls `init/2` with the opts.
  """

  alias Masu.{Column, Query}
  alias Masu.Source.Ecto, as: EctoSource

  @typedoc "The state of a source; a source keeps what it needs between calls."
  @type state :: term()

  @doc "Starts the source from what the grid was given."
  @callback init(input :: term(), opts :: keyword()) :: state()

  @doc """
  Applies a query: the rows that `count/1` counts and `rows/3` reads are
  from now on those of the query, in its order. The query is checked
  against the columns (`Masu.Query`).
  """
  @callback prepare(state(), Query.t(), [Column.t()]) :: state()

  @doc "How many rows the query has."
  @callback count(state()) :: non_neg_integer()

  @doc "The rows from `offset` (from 0), at most `limit` of them."
  @callback rows(state(), offset :: non_neg_integer(), limit :: pos_integer()) :: [term()]

  @doc """
  Whether the source can sort and filter by a column. A database can sort
  only by a field it stores, not by a function of the row; the grid makes
  such a column one that does not sort or filter.
  """
  @callback supports?(state(), Column.t()) :: boolean()

  @doc """
  Takes changes into the source's rows (see `Masu.Live`): `{:upsert, row}`
  and `{:delete, row_or_id}`, oldest first, with the grid's function that
  gives a row's id. The grid calls `prepare/3` after it.

  A source that reads its rows anew for each query (as a database does)
  does not need it: without it, the grid asks the query again.
  """
  @callback change(state(), [Masu.Live.change()], (term() -> term())) :: state()

  @doc """
  The values of a column among the rows of a query, with how many rows
  have each, the most frequent first: what a column's filter menu offers.
  `search` narrows them to the values that contain it, without case.
  `nil` counts as a value: the rows with no value.

  A source without it offers no values: the menu then filters by what the
  person types.
  """
  @callback values(state(), Column.t(), Query.t(), [Column.t()], keyword()) :: [
              {term(), non_neg_integer()}
            ]

  @doc """
  The rows with the given ids, among the rows the source may show (its
  query without the person's filters): the rows a person edits. A row
  that is not there is not given, so that no one edits a row the grid
  would not show them.
  """
  @callback fetch(state(), ids :: [term()], (term() -> term())) :: [term()]

  @doc """
  The place (from 0) of the row with an id in the rows of the query, in
  their order, or `nil` when the query does not have it: where another
  person's cell is in this person's order (`Masu.Presence`).
  """
  @callback locate(state(), id :: term(), (term() -> term())) :: non_neg_integer() | nil

  @doc """
  For a tree (`Masu.Tree`): the rows from `offset`, as `rows/3` gives
  them, each with where it is in the tree (`t:Masu.Tree.node_info/0`), or
  `nil` when the source is not a tree. The rows of a tree are the roots
  and the children of the rows that are open (`Masu.Query`'s `expanded`),
  in order.
  """
  @callback nodes(state(), offset :: non_neg_integer(), limit :: pos_integer()) ::
              [{term(), Masu.Tree.node_info()}] | nil

  @doc """
  For a tree: the ids of the siblings of a row (it among them) that have
  children: the rows that open with the row's level (`*`).
  """
  @callback siblings(state(), id :: term()) :: [term()]

  @doc """
  The totals of the rows of the query (`Masu.Group`): the value of each
  column with an `aggregate`, by its key.
  """
  @callback totals(state()) :: %{String.t() => term()}

  @optional_callbacks supports?: 2,
                      totals: 1,
                      change: 3,
                      values: 5,
                      fetch: 3,
                      locate: 3,
                      nodes: 3,
                      siblings: 2

  @type t :: %__MODULE__{module: module(), state: state()}

  defstruct [:module, :state]

  @doc """
  The source for what a grid was given: a list, an Ecto query or schema
  (with the `:repo` option), or `{module, opts}`.
  """
  @spec new(term(), keyword()) :: t()
  def new({module, opts}, grid_opts) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :prepare, 3) do
      %__MODULE__{module: module, state: module.init(opts, grid_opts)}
    else
      ecto(module, opts, grid_opts)
    end
  end

  def new(rows, opts) when is_list(rows),
    do: %__MODULE__{module: Masu.Source.List, state: Masu.Source.List.init(rows, opts)}

  def new(queryable, opts), do: ecto(queryable, opts, opts)

  defp ecto(queryable, _source_opts, opts) do
    if Code.ensure_loaded?(EctoSource) and EctoSource.queryable?(queryable) do
      %__MODULE__{module: EctoSource, state: EctoSource.init(queryable, opts)}
    else
      raise ArgumentError,
            "a Masu grid takes a list of rows, an Ecto query or schema with a :repo, " <>
              "or {module, opts} of a Masu.Source, got: #{inspect(queryable)}"
    end
  end

  @doc false
  @spec prepare(t(), Query.t(), [Column.t()]) :: t()
  def prepare(%__MODULE__{module: module, state: state} = source, query, columns),
    do: %{source | state: module.prepare(state, query, columns)}

  @doc false
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{module: module, state: state}), do: module.count(state)

  @doc false
  @spec rows(t(), non_neg_integer(), pos_integer()) :: [term()]
  def rows(%__MODULE__{module: module, state: state}, offset, limit),
    do: module.rows(state, offset, limit)

  @doc false
  @spec change(t(), [Masu.Live.change()], (term() -> term())) :: t()
  def change(%__MODULE__{module: module, state: state} = source, changes, row_id) do
    if function_exported?(module, :change, 3),
      do: %{source | state: module.change(state, changes, row_id)},
      else: source
  end

  @doc false
  @spec values(t(), Column.t(), Query.t(), [Column.t()], keyword()) :: [
          {term(), non_neg_integer()}
        ]
  def values(%__MODULE__{module: module, state: state}, column, query, columns, opts) do
    if function_exported?(module, :values, 5),
      do: module.values(state, column, query, columns, opts),
      else: []
  end

  @doc false
  @spec fetch(t(), [term()], (term() -> term())) :: [term()]
  def fetch(%__MODULE__{module: module, state: state}, ids, row_id) do
    if function_exported?(module, :fetch, 3),
      do: module.fetch(state, ids, row_id),
      else: []
  end

  @doc false
  @spec locate(t(), term(), (term() -> term())) :: non_neg_integer() | nil
  def locate(%__MODULE__{module: module, state: state}, id, row_id) do
    if function_exported?(module, :locate, 3), do: module.locate(state, id, row_id)
  end

  @doc false
  # The rows from `offset` with their places in the tree, or nil: the
  # source is not a tree.
  @spec nodes(t(), non_neg_integer(), pos_integer()) :: [{term(), map()}] | nil
  def nodes(%__MODULE__{module: module, state: state}, offset, limit) do
    if function_exported?(module, :nodes, 3), do: module.nodes(state, offset, limit)
  end

  @doc false
  @spec totals(t()) :: %{String.t() => term()}
  def totals(%__MODULE__{module: module, state: state}) do
    if function_exported?(module, :totals, 1), do: module.totals(state), else: %{}
  end

  @doc false
  @spec siblings(t(), term()) :: [term()]
  def siblings(%__MODULE__{module: module, state: state}, id) do
    if function_exported?(module, :siblings, 2), do: module.siblings(state, id), else: []
  end

  @doc false
  @spec supports?(t(), Column.t()) :: boolean()
  def supports?(%__MODULE__{module: module, state: state}, column) do
    if function_exported?(module, :supports?, 2), do: module.supports?(state, column), else: true
  end
end
