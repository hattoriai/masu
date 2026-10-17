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

## Editing

* `edit(view, id, edits)`: edits cells as a person does, with a list of
  `{row_id, key, value}` (the value as the browser sends it: a string, or
  `nil` to empty the cell). Gives `:ok`, or `{:error, errors}` with
  `{row_id, key, message}` for each cell that was not saved.

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

## What these tests do not cover

`Masu.Test` does not run the browser: the drawing of the rows, the
keyboard, the selection and the clipboard are tested by Masu's own
browser tests.
