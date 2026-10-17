# Export, selection and large tables

## Export

```heex
<.data_grid id="orders" source={Order} repo={Repo} export>
```

`export` adds an Export menu to the toolbar: CSV, and Excel (XLSX). The
file has every row of the person's query (their order, filters and
search), with the columns that show, in their order, and their labels
as its first row. `export={[:csv]}` offers CSV alone.

A grid exports only when it says so: without `export` it has no menu,
and the server refuses an export it is asked for. It is an assign like
any other, so it can be the person's to have, and change as they use
the page:

```heex
<.data_grid id="orders" source={Order} repo={Repo} export={@current_scope.user.admin?}>
```

When it turns `false` the menu goes, and the grid gives no link, to an
event a browser could still send. A grid that never exports needs no
route.

The file downloads from a route of your router, which `masu_exports`
mounts:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import Masu.Router

  scope "/" do
    pipe_through [:browser, :require_authenticated_user]

    live "/orders", OrdersLive
    masu_exports "/masu/exports"
  end
end
```

The menu asks the grid for a link, and the browser downloads the file
from it, as a download of its own (its progress, and its cancel, are the
browser's). The rows are read a block at a time as the file goes, from
an Ecto source by key, and written to the response as they are read:
the file is never whole in memory, nor on disk, nor sent over the
LiveView's socket. A cancelled download stops the reading.

**The link.** Its token is encrypted with the endpoint's
`secret_key_base`, and names a ticket that the grid's LiveView holds,
not the export: a link in the browser's history, or in a log, gives
nothing. A ticket is good for one download, for five minutes, and while
the LiveView that made it runs. Put the route in a scope that requires
the person to be signed in, as the grid's LiveView does: the token
proves the grid made the export, the pipeline that the person is still
who they were. The route goes through the scopes it is in, and the
endpoint's `script_name`. With the app on several nodes, the download
must reach a node connected to the LiveView's (distributed Erlang, as
`Phoenix.PubSub` has it).

The file is named after the grid and the day, `orders-2026-10-17.csv`:
in its `Content-Disposition`, with no character that could end the
header, and in UTF-8.

**Values.** In CSV (UTF-8), values are as the browser gets them
(decimals with their digits, dates in ISO 8601); text that a spreadsheet
would run as a formula (it starts with `=`, `+`, `-`, `@`) starts with
`'`. In XLSX, numbers, decimals, dates, times and booleans are cells of
their type. A column of your own HEEx exports its value, not its HTML.
Grouped rows and a tree's rows are exported as rows, every one of them.
An XLSX sheet has Excel's 1,048,576 rows at most; a CSV file has every
row.

An app exports a grid itself with `Masu.Live.export/1`, in the LiveView.
It gives the export as data (`Masu.Export`), which `Masu.Export.write/4`
writes to a file anywhere (in a task, in a background job, with
`progress:`), and `Masu.Export.stream/2` streams, to a response of your
own:

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

## Large tables: counts

A grid counts its rows to scroll over them all, and a count can be the
slowest query of all: a `count(*)` of an ad-hoc query, a scan of a
warehouse. `count` says when the grid counts:

| `count` | The grid |
| --- | --- |
| `:exact` (the default) | counts with each query |
| `:deferred` | shows the first rows, then counts in a task: the first screen does not wait for the count |
| `:none` | does not count, until the person goes to the end (Ctrl+End, or the scrollbar's end), once |

```heex
<.data_grid id="events" source={Event} repo={Repo} count={:none}>
```

Until it knows the count, the grid scrolls over the rows it read and a
block more, and grows as a block comes back full; a block that comes
back short says where the rows end. A screen reader hears that the count
is not known (`aria-rowcount="-1"`), and the status says "1,000+ rows".
A source of your own may not know its count either (`{:at_least, n}`,
`:unknown`), or know it with its rows; see [Sources](sources.md).

## Pages

The grid scrolls by default. `paging={:pages}` shows a page of rows at a
time, with a pager under the grid: "1–50 of 1,234", Previous and Next,
and a page to go to:

```heex
<.data_grid id="report" source={Order} repo={Repo} paging={:pages} page_size={50} url>
```

Each page is a block of the source, as the grid reads any rows: a page
needs nothing of a source. The page is part of the person's view (in the
URL with `url`, in saved views, `"page" => "3"`); a new order, filter or
search goes to the first page. Without a count, the pager says "1–50 of
1,000+" and has a next page while the page is full. New rows (`create`)
go on the last page.

## Testing

`Masu.Test.export/4` exports a grid as its menu does, downloads the file
through your router's route, and gives it (`{name, binary}`);
`Masu.Test.export_url/3` gives the link, to test the route's pipeline.
`Masu.Test.select/4`, `select_all/3` and `selection/2` select rows and
read the selection. `Masu.Test.count/2` says what a grid knows of its
count, `ask_count/2` asks for it as Ctrl+End does, and `page/3` goes to
a page.
