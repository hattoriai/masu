# Testing

`Masu.Test` reads and queries the grids of a LiveView in
`Phoenix.LiveViewTest`, with no browser.

```elixir
import Masu.Test

test "finds the late orders", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/orders")

  assert total(view, "orders") == 120

  view
  |> filter("orders", [{"status", :eq, "late"}])
  |> sort("orders", {"total", :desc})

  assert [%{"number" => "A-1042", "total" => "250.50"} | _] = rows(view, "orders")
end
```

The functions send the events that the browser sends, so the grid
applies a sort, a filter or a search as it does for a person: the source
sorts, filters and counts (in the database, for an Ecto source), and
`rows/3` reads the rows it gives.

## Reading

* `rows(view, id, from: 0, count: 100)`: the rows, in order. A row is a
  map of each column's key to its value as the browser gets it: numbers
  and booleans as they are, decimals as strings, dates and times in ISO
  8601, and for a column of your own HEEx the text of its cell.
* `ids(view, id)`: the ids of the rows.
* `total(view, id)`: how many rows the query has.
* `columns(view, id)`: the labels, in order.
* `values(view, id, key, search: nil)`: what the column's filter menu
  offers, as `{value, count}`, the most frequent first.
* `place(view, id, row_id)`: where the row is in the grid's order (from
  0), or `nil` when its filters leave it out: what a person who follows
  someone scrolls to.

## Editing

* `edit(view, id, edits)`: edits cells as a person does, with a list of
  `{row_id, key, value}` (the value as the browser sends it: a string, or
  `nil` to empty the cell). Gives `:ok`, or `{:error, errors}` with
  `{row_id, key, message}` for each cell that was not saved. An edit
  `{row_id, key, value, before}` carries the value the person saw, and is
  refused when the cell changed meanwhile.

## Querying

Each returns the view, so they pipe:

* `sort(view, id, sorts)`: a key, `{key, :asc | :desc}`, or a list of
  them, the first the most important. `[]` takes the order away.
* `filter(view, id, filters)`: a list of `{key, op, value}`, which
  replaces the grid's filters. See `Masu.Filter` for the operators.
* `search(view, id, text)`: as the search box.

A query that the grid refuses (a filter on a column that does not filter,
a value that is not of the column's type) fails the test with the
grid's reason.

## Layout and views

* `layout(view, id, changes)`: moves, hides, pins and resizes columns,
  as the columns menu and the headers do: `order: keys`, `hidden: keys`,
  `pinned: %{key => :start | :end}`, `widths: %{key => pixels}`.
* `view(view, id)`: the grid's view, as its params (`%{}` is the grid's
  own view; see `Masu.View`).
* `apply_view(view, id, params)`: applies a view, as a link or a saved
  view does; gives the keys of the parts that no longer apply.

`columns/2` and `rows/3` read the columns that show, in their order.

## Groups and totals

* `group(view, id, keys)`: groups by columns, as the header menu does;
  `[]` stops.
* `groups(view, id, opts)`: the groups' rows, as maps of `:id`, `:key`,
  `:value`, `:count`, `:level`, `:expanded` and `:totals`.
* `totals(view, id)`: the row of totals, by column key.

## Counts and pages

* `count(view, id)`: `{:exact, n}`, or `{:at_least, n}` while the grid
  does not know its count; `total/2` gives `n`.
* `ask_count(view, id)`: asks for the count, as Ctrl+End does.
* `page(view, id, page)`: goes to a page (from 1) of a grid with
  `paging={:pages}`, and gives the ids of its rows.

## New and deleted rows

* `add_rows(view, id, rows)`: adds rows as "+ New row" does, each a map
  of column keys to values; `{:ok, ids}`, or `{:error, results}`.
* `delete_rows(view, id, ids_or_selection)` and `restore_rows(view, id,
  undo)`: deletes rows (or `:selection`), and brings them back.

## Export and selection

* `export(view, id, format, opts \\ [])`: exports as the Export menu
  does, downloads the file through your router's export route, and gives
  it, `{name, binary}`; `conn:` a conn with what the route's pipeline
  wants (a signed-in user).
* `export_url(view, id, format)`: the link the browser would get, to test
  the route itself (that it refuses a person who is not signed in).
* `select(view, id, ids, on \\ true)`, `select_all(view, id, on \\ true)`
  and `selection(view, id)`.

## Trees and details

* `nodes(view, id, opts)`: the rows of a tree, as maps of `:id`,
  `:level`, `:children` and `:expanded`.
* `expand(view, id, row_id)`, `collapse(view, id, row_id)` and
  `expand_siblings(view, id, row_id)`: as the arrows and `*`.
* `detail(view, id, row_id, open \\ true)`: opens a row's detail, which
  `render/1` then has; a grid in it is read with its own id.

## Menus of your own

* `actions(view, id, :header | :cell, key)`: the labels of the items
  the grid offers for a column.
* `header_action(view, id, label, key)` and `cell_action(view, id,
  label, key, row_id, opts)`: run an item, as a click on it does; its
  panel is then in `render/1`. `close_panel(view, id)` closes it. See
  [Menus of your own](menus.md).

## What these tests do not cover

`Masu.Test` does not run the browser: the drawing of the rows, the
keyboard, the selection and the clipboard are tested by Masu's own
browser tests.
