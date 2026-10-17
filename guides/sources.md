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
* the count is a `count(*)` of the query;
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
against the grid's columns. The optional `supports?/2` says whether the
source can sort and filter by a column; the grid turns off the others.
