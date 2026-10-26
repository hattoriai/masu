# Layout and views

A person arranges a grid the way they work: some columns pinned, some
hidden, the rest in their order and at their width, with their sort,
filters and search. That arrangement is their **view** (`Masu.View`),
and a grid can keep it in the URL, so that a link opens it, and in a
store, so that it comes back tomorrow and can be shared by name.

```heex
<.data_grid
  id="orders"
  source={Order}
  repo={Repo}
  columns_menu
  url
  views={MyApp.GridViews}
  user={%{id: @current_user.id}}
>
  <:col field={:number} pinned={:start} />
  <:col field={:customer} />
  <:col field={:notes} hidden />
  <:col field={:total} type={:decimal} pinned={:end} />
</.data_grid>
```

## The layout

`pinned={:start}` or `pinned={:end}` on a `:col` keeps the column in
view while the others scroll sideways: the pinned to the start show
first, then the others, then the pinned to the end. `hidden` starts the
column hidden. Both are where the grid starts; the person changes them.

A person moves a column by dragging its header (a click still sorts),
or with **Alt+Shift+←** and **Alt+Shift+→** on a header; a column moves
among the columns of its pin. They resize it by dragging the edge of its
header (a double click fits it to its content); a column that grows
(`grow`, see [Columns](columns.md#a-column-that-takes-the-room)) is then
the width they gave it.

`columns_menu` adds a **Columns** button to the toolbar: a menu of every
column, to show and hide it, pin it to the start or the end, and move it
up or down (past the hidden ones), with a search box for a grid of many
columns, and **Show all**.

A hidden column still sorts, filters and searches: a filter on it shows
as a chip, and stays.

## The URL

With `url`, the view goes into the URL's params, under the grid's id, as
it changes, so a link reproduces what the person sees:

```text
/orders?orders[sort]=-total&orders[q]=acme&orders[group]=status&orders[hide]=notes,seats&orders[pin]=number:start
```

A grid of pages (`paging={:pages}`) keeps its page there too,
`orders[page]=3`.

Only what differs from the grid's own view (of its attributes) is in the
params (see `Masu.View` for each of them), and the URL is replaced, not
pushed: a sort is not a step of the browser's history. A link opened
later, or the back button to a page of another view, applies its view.

`url` needs the `Masu.Live` hook (`on_mount Masu.Live`), which reads the
params, and a LiveView at the router. The LiveView does not need a
`handle_params/3` of its own; if it has one, it is called as usual.

## Each person's view, and named views

With `views` (a `Masu.Views` store) and `user`, the grid keeps each
person's last view, and opens with it when they come back (a link's view
wins over it). A **Views** button in the toolbar lists the person's
named views and the shared ones, applies one, deletes one of the
person's own, goes back to the grid's own view, and saves the view as it
is under a name, for the person or shared with everyone who has the
grid. The button shows the name of the view that shows, if it is one.

Masu has two stores:

* `Masu.Views.Ecto`, a table in your database:

  ```elixir
  defmodule MyApp.GridViews do
    use Masu.Views.Ecto, repo: MyApp.Repo
  end
  ```

  `mix masu.gen.views` writes the migration of its table (`masu_views`,
  or `--table` of your own); then `mix ecto.migrate`.

* `Masu.Views.Memory`, in memory, for development and tests: start it
  in your supervision tree.

A store of your own implements the five callbacks of `Masu.Views`. Views
are kept by `views_key` (the grid's id unless given): give two grids of
the same rows on two pages the same key to share their views.

In an app of many accounts, give the grid `views_scope`, so that each
account's views are its own:

```heex
<.data_grid
  id="orders"
  source={@orders}
  repo={Repo}
  views={MyApp.GridViews}
  user={@current_scope.user}
  views_scope={@current_scope.account.id}
>
```

Without it, every account has the grid's one pool of views: a view
shared in one account is offered in every other, with its name and its
params (a filter's values, such as a customer's name). The store keeps
a scope's views under `"orders@42"`, the key and the scope. A view
never shows more rows than the grid's `source` does: applying one, the
grid takes its params as it takes a link's, as filters, order and
columns of the rows the source already has. So scope the `source` to
the account too.

## Views that no longer apply

A view is kept as its params, so it outlives changes to the grid: a
column added since takes its declared place, a column removed is left
out, and a sort or filter on a column that no longer sorts or filters,
or a filter value that no longer reads, is dropped. A part past a bound
of [What the browser may send](limits.md#what-the-browser-may-send), or
with a NUL character, is dropped too: a search of more than 1,000 bytes
(shown as "search"), more than 100 filters ("filters"), sorts ("sort") or
groups ("group"), or a filter whose value is too long (shown by its
column). The whole part goes, never a cut of it. The grid says so to the
person ("Part of this view no longer applies: plan"); a link or a saved
view never fails a grid.

## Following someone, with Issho

When a person follows someone (see [Collaboration](collaboration.md), optional), the grid shows that
person's order, filters and search; the layout stays the follower's own.

## Testing

`Masu.Test.view/2` gives a grid's view as its params,
`Masu.Test.apply_view/3` applies params, and `Masu.Test.layout/3` moves,
hides, pins and resizes columns as the menus do. With `url`,
`Phoenix.LiveViewTest.assert_patch/2` sees the URL change.
