# Sources

A grid never holds all its rows. It asks its source for the rows of its
query, how many there are, and the rows the browser shows, a block at a
time, as the person scrolls. `Masu.Source` is the behaviour; Masu has two
sources, and a source of your own is a module.

## A list

```heex
<.data_grid id="users" rows={@users}>
```

The rows are maps or structs. When the query changes, the list filters,
searches and sorts them in the LiveView's process, once, and keeps the
result as a tuple, so each block is read without walking the list.

A list is for up to about 10,000 rows: it sorts and searches them in
tens of milliseconds. Each LiveView holds its own rows, about 1 KB a
row, and at 100,000 rows a sort takes about 0.4 seconds and a LiveView
about 100 MB. Past 10,000 rows, or for rows in a database, give the
grid an Ecto source. If you need a larger list in memory, [open an
issue](https://github.com/hattoriai/masu/issues) or a pull request. See [Known limits](limits.md).

Text sorts without case, an empty value (`nil`) after every value in
both directions, and rows that compare equal keep their order. Decimals
sort by their exact value.

When the LiveView gives the grid new rows, the grid keeps the person's
order, filters and search, and applies them to the new rows.

## Row ids

A grid knows each row by its id: the row's `id` unless `row_id` gives
another, a function of the row:

```heex
<.data_grid id="orders" rows={@orders} row_id={& &1.number}>
```

The rows of a report or an ad-hoc query often have no id. A grid that
needs none (it shows rows, sorts, filters, pages, copies and exports
them) knows such a row by its place in the query. `row_id={:position}`
says so for every row, whatever ids the rows have.

A place is not an id from one query to the next: the first row of one
order is not the first of another. What needs a row's id to stay the
same needs a real one, and a grid with `row_id={:position}`, or a row
without an id, refuses it, saying so:

| Feature | Why it needs an id that stays |
| --- | --- |
| `changeset`, `update` | an edit saves the row it was made on |
| `create`, `struct` | a new row takes its place among the others by its id |
| `delete`, `deletable` | a delete, and its undo, are of rows by their ids |
| `selectable` | the selection stays as the order and filters change |
| `live` | a change from the topic replaces the row with its id |
| `presence` | another person's cell is on a row, in each person's own order |
| `:detail` | an open detail stays with its row |
| `tree` | a row's parent is named by its id |

## An Ecto query or schema

```heex
<.data_grid id="orders" source={Order} repo={MyApp.Repo}>
<.data_grid id="orders" source={from(o in Order, where: o.shop_id == ^@shop.id)} repo={MyApp.Repo}>
```

The database does the work:

* a sort is an `ORDER BY`, and after it the schema's primary key, so that
  rows of equal values do not move from one block to the next. A query
  with no sort reads its rows in the order of the primary key (or of its
  own `order_by`);
* a filter and the search are a `WHERE`, added to the query's own;
* the count is a `count(*)` of the query, when the grid asks for it
  (see `count` in [Export, selection and large tables](export.md));
* each block is one `LIMIT`: the block after a block it read is read by
  the sort values of that block's last row, not by `OFFSET` (see
  [Export, selection and large tables](export.md)).

The query may have its own `where`, `join` and `preload`. A column sorts
and filters in the database when it names a field of the query's first
source (`field={:total}`); a column with a `value` function is shown but
does not sort, filter or search.

The text filters and the search compare without case, with
`lower(field) LIKE ...`, which PostgreSQL, MySQL and SQLite all run. On a
large table, an index on `lower(field)` (or a trigram index in
PostgreSQL) keeps the search fast. A sort needs an index on its column,
as any `ORDER BY` with a `LIMIT` does.

`repo_opts` are given to each call to the repo, for example the `prefix`
of a tenant's schema:

```heex
<.data_grid id="orders" source={Order} repo={MyApp.Repo} repo_opts={[prefix: @tenant]}>
```

A jump into the middle of a large table (the scrollbar dragged) is an
`OFFSET`, which gets slower deep into it: the database still reads the
rows before it. See [Known limits](limits.md).

## A read of your own

Masu's way to read a block (by key, see above) suits most tables. A
table may need another: its own index, a cache, a warehouse where each
query costs. `read` keeps the rest of the Ecto source (the filters, the
search, the count, the filter menu's values, the selection, the export)
and reads each block your way:

```heex
<.data_grid id="orders" source={Order} repo={MyApp.Repo} read={&MyApp.Orders.read/2}>
```

```elixir
def read(query, %{offset: offset, limit: limit, order: order, after: after_row}) do
  query |> offset(^offset) |> limit(^limit) |> MyApp.Repo.all()
end
```

`query` is the grid's query, with its filters, search and order. Its
rows are the rows from `offset`, at most `limit` of them; `order` is the
order (`[desc: :placed_at, asc: :id]`, the primary key always last, or
`nil` when it is the query's own `order_by`). `after` is the sort values
of the last row of the block before (`[placed_at: ~U[...], id: 41]`), to
read the block after it by key, or `nil`: the first block, or a jump
(the scrollbar dragged). It gives what `c:Masu.Source.rows/3` gives: the
rows, `{rows, count}`, or `{:error, reason}`.

The grid takes `read` when it starts. A tree and the open groups of a
grouped grid are read Masu's way. For a source that is not an Ecto
query, write a source of your own.

## A source of your own

A source is a module with the `Masu.Source` callbacks, given as
`source={{MySource, opts}}`:

```elixir
defmodule MyApp.SearchSource do
  @behaviour Masu.Source

  @impl true
  def init(opts, _grid_opts), do: %{index: Keyword.fetch!(opts, :index), query: nil}

  @impl true
  def prepare(state, %Masu.Query{} = query, _columns), do: %{state | query: query}

  @impl true
  def count(state), do: MyApp.Search.count(state.index, state.query)

  @impl true
  def rows(state, offset, limit), do: MyApp.Search.page(state.index, state.query, offset, limit)
end
```

`prepare/3` gets the query with every key and value already checked
against the grid's columns.

A source need not know its count: `count/1` may give `{:at_least, n}`
(a search engine's "10,000+") or `:unknown`, and the grid scrolls over
the rows it read, and grows as it reads more. `rows/3` may give
`{rows, count}`, when the count came with the rows (a `total_count` of
the same request), and the grid takes it. The optional `supports?/2` says whether the
source can sort and filter by a column; the grid turns off the others.

A source of a tree implements `nodes/3` and `siblings/2` too: see
[Trees and details](trees.md).

### Columns of the source

A source whose columns are known when its query runs (a query tool,
a warehouse) gives them with the optional `columns/1`, and a grid with
no `:col` slots takes them:

```elixir
@impl true
def columns(state), do: state.result.columns
```

Each is a key, or a keyword list or map of a `:col`'s attributes. Without
a `field`, a column reads its place of a row that is a list; without a
`type`, it takes the type of its values. See
[Columns not known in advance](columns.md#columns-not-known-in-advance).

### The filters a source runs

A source that Masu does not translate itself (an API, a search engine,
another query tool) often runs fewer filters than Masu has. The optional
`filters/2` gives those it runs for a column:

```elixir
@impl true
def filters(_state, %Masu.Column{key: "notes"}), do: []
def filters(_state, _column), do: [:eq, :neq, :gt, :lt, :gte, :lte, :contains, :is_nil, :not_nil]
```

The grid then offers only those: the filter menu of each column, the
chips, the menu of a cell (`cell_menu`), a view's params from a link or
a saved view (a filter the source does not run is dropped and named, as
a filter of a column that is gone), and `Masu.Test.filter/3`. The server
refuses the others, so `prepare/3` never gets them. `[]` is a column it
does not filter by. Without `filters/2`, a column has every filter of
its type.

Masu runs "between" as "at least" and "at most" for a source that has
those and not it: the person sees one filter, and the source gets two.
An enum whose source has no "is one of" (`:in`) filters by one value,
"is" or "is not", from a list of its `values`.

What each operator means, and what it is in SQL:

| Operator | Means | SQL |
| --- | --- | --- |
| `:eq`, `:neq` | equal, or not, to the value; `:neq` keeps the rows with no value | `=`, `<>` (or `IS DISTINCT FROM`) |
| `:gt`, `:gte`, `:lt`, `:lte` | greater or less than the value | `>`, `>=`, `<`, `<=` |
| `:between` | from the first value to the second, both in | `BETWEEN` |
| `:in` | one of a list of values | `IN (...)` |
| `:contains`, `:not_contains` | has the text, without case | `ILIKE '%x%'`, `NOT ILIKE '%x%'` |
| `:starts_with`, `:ends_with` | starts or ends with the text, without case | `ILIKE 'x%'`, `ILIKE '%x'` |
| `:is_nil`, `:not_nil` | no value, or any value | `IS NULL`, `IS NOT NULL` |

The text operators are for `:text` and `:enum` columns only. A source
whose LIKE has case (and a `%` or `_` in the value) escapes and lowers
as it can; it says it runs `:contains` only if it does.

## Slow sources

A grid reads its source inside the event that asks for the rows: the
rows go back in its answer, with no process of its own. For a list, or
a database query on its indexes, that is the right way, and it is the
grid's own (`load={:inline}`).

A slow source (a warehouse, a search engine, a query a person wrote)
would hold the LiveView while it runs: no other event, no presence. A
grid with `load={:async}` reads it in a task instead:

```heex
<.data_grid id="events" source={{MyApp.WarehouseSource, table: "events"}} load={:async} timeout={30_000}>
```

  * a new order, filter, search or page, the first rows, a block of rows
    as the person scrolls, and a count (`count={:none}`) run in a task
    (`start_async`); the LiveView answers meanwhile;
  * the grid says "Running…", with Stop, and keeps its rows until the new
    ones come; the last read asked for is the one taken;
  * `timeout` (milliseconds) stops a read that takes longer, and says so;
  * a source's error, a raise or `{:error, reason}` from `rows/3`, shows
    in the grid, with Run again, and the LiveView lives on.

Edits, new and deleted rows, and the export read as they do; a column of
`type={:auto}` reads its first block for its type before the task.
`Masu.Test` waits for the tasks: a test reads the same either way.

## Queries of your own (controlled grids)

An app that runs its queries itself (with its own timeout, count, cache
and process) uses the grid as a view of them: with `on_query`, the grid
shows the rows it is given, as they are, and tells the app what the
person did, for the app to run its query again:

```heex
<.data_grid
  id="results"
  rows={@result.rows}
  columns={@result.columns}
  total={@result.total_count}
  loading={@running}
  on_query={&send(self(), {:results_query, &1})}
  paging={:pages}
  page_size={1000}
  max_block={1000}
  multi_sort={false}
/>
```

```elixir
def handle_info({:results_query, %{query: query, offset: offset, limit: limit}}, socket) do
  {:noreply, run_query(socket, query.filters, query.sorts, offset, limit)}
end
```

  * The grid never sorts, filters or pages the rows itself. A sort, a
    filter, the search, a page or a view (a link, a saved view) calls
    `on_query` with `%{query: %Masu.Query{}, page: n, offset: n, limit:
    n}`: the person's view, and the rows of its page (`limit` is `nil`
    in a grid that scrolls: its rows are all the rows).
  * `rows` are the rows of the page, and `total` how many the query has.
  * `loading` says that the app's query runs: the grid says "Running…"
    and keeps its rows. When the app renders the grid with `loading`
    false, its rows are the answer, the same as before or not.
  * `multi_sort={false}` sorts by one column at a time, as most query
    tools do; a click on a header turns its order, and a third takes it
    away.
  * Each column offers the filters of its type. An app whose queries
    run fewer gives each column the operators it runs, with `filters` (a
    `:col`'s attribute, or a key of a column of `columns`): the filter
    menu, the chips and the menu of a cell offer only those, and the
    grid refuses the others before they reach `on_query`. Masu adds
    "between" for a column with "at least" and "at most":

    ```elixir
    columns = for name <- result.columns, do: %{key: name, label: name, filters: [:eq, :neq, :gt, :lt, :gte, :lte, :contains, :is_nil, :not_nil]}
    ```

A controlled grid does not take what reads or writes rows beyond those it
is given: `changeset`, `update`, `create`, `delete`, `selectable`,
`export`, `live`, `tree` and `group_by`.
