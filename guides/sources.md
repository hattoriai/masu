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

Sorting a hundred thousand rows takes about a fifth of a second. Past
that, or for rows in a database, give the grid an Ecto source.

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
* each block is one `LIMIT` and `OFFSET`.

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

An `OFFSET` gets slower deep into a large table: the database still
reads the rows before it. See [Known limits](limits.md).

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
