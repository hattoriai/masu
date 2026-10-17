# Export, selection and large tables

## Export

```heex
<.data_grid id="orders" source={Order} repo={Repo} export>
```

`export` adds an Export menu to the toolbar: CSV, and Excel (XLSX). The
file has every row of the person's query (their order, filters and
search), with the columns that show, in their order, and their labels
as its first row. It is written in a task, the LiveView goes on, the
button says how far it got (with the `Masu.Live` hook), and the browser
downloads it when it is done. `export={[:csv]}` offers CSV alone.

In CSV, values are as the browser gets them (decimals with their digits,
dates in ISO 8601); text that a spreadsheet would run as a formula (it
starts with `=`, `+`, `-`, `@`) starts with `'`. In XLSX, numbers,
decimals, dates, times and booleans are cells of their type. A column of
your own HEEx exports its value, not its HTML. Grouped rows and a tree's
rows are exported as rows, every one of them.

An app exports a grid itself with `Masu.Live.export/1`, in the LiveView.
It gives the export as data (`Masu.Export`), which `Masu.Export.write/4`
writes to a file anywhere (in a task, in a background job), and
`Masu.Export.stream/1` streams as CSV:

```elixir
def handle_event("email_report", _params, socket) do
  export = Masu.Live.export("orders")

  Task.start(fn ->
    path = Path.join(System.tmp_dir!(), "orders.xlsx")
    :ok = Masu.Export.write(export, :xlsx, path)
    MyApp.Mailer.deliver_report(path)
  end)

  {:noreply, socket}
end
```

The rows are read from the source a block at a time.

## Selecting rows

```heex
<.data_grid id="orders" source={Order} repo={Repo} selectable on_select={&send(self(), {:selected, &1})}>
```

`selectable` puts a box in the first cell of each row:

| Key or click | Does |
| --- | --- |
| A row's box, Space on the first column, Ctrl (⌘) and a click | selects the row, or takes it out |
| Shift and a row's box | selects the rows from the last box clicked |
| The box of the first header | selects every row of the query (or, when every row is, none) |

Above the grid, "4 selected", or "All 1,204 selected", with Clear.

**Every row of the query** is not a list of ids: it is the query, less
the rows the person takes out of it, so that an action on a million rows
does not send a million ids. `Masu.Live.selected/1`, in the LiveView,
gives `{:ids, ids}`, or, for every row of an Ecto source's query,
`{:query, query}`: an `Ecto.Query` of those rows, with the person's
filters and search, for `Repo.update_all/3` or a background job:

```elixir
def handle_event("archive", _params, socket) do
  case Masu.Live.selected("orders") do
    {:ids, ids} -> Orders.archive(ids)
    {:query, query} -> Repo.update_all(query, set: [archived: true])
  end

  {:noreply, socket}
end
```

`on_select` is called with `%{count: n, all: boolean}` when the
selection changes. The selection stays as the person scrolls and sorts;
a selection of every row follows the query as it changes.

## Large tables: paging by key

An Ecto source reads the block after a block it read by the sort values
of that block's last row, as `WHERE (a, b, id) > (...)`, not by an
`OFFSET`, which the database counts row by row: the last block of a
table of millions of rows is as fast as the first. A jump into the
middle (the scrollbar dragged) is an `OFFSET`; the blocks after it are
read by key again. It works with descending orders and with `NULL`s
(after every value in PostgreSQL, before them in SQLite and MySQL), and
with the primary key as the last sort, which the grid always adds. A
query with its own `order_by` (and no sort of the person's) is read by
`OFFSET`.

## Testing

`Masu.Test.export/3` exports a grid as its menu does and gives the file
(`{name, binary}`). `Masu.Test.select/4`, `select_all/3` and
`selection/2` select rows and read the selection.
