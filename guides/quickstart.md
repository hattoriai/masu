# Quickstart

This guide adds a data grid to a Phoenix 1.8 app with LiveView 1.2 (a
Phoenix 1.7 app with LiveView 1.1 works the same way). At the end, a
LiveView shows its users in a grid that sorts, searches and scrolls, and
then the orders of a table, read from the database a block at a time.

Your app does not run Node.js for Masu. The Hex package has the built
bundle, and your esbuild profile imports it from `deps/`.

## 1. Add the dependency

In `mix.exs`:

```elixir
def deps do
  [
    {:masu, "~> 0.3"}
  ]
end
```

Then run `mix deps.get`.

## 2. Run the installer

```sh
mix masu.install --dry-run   # shows the changes as a diff
mix masu.install
```

The installer changes two files, and prints what it changed:

* `assets/js/app.js`: it adds `import { Masu } from "masu"` and puts
  `Masu` in the `hooks` of the `LiveSocket`.
* `assets/css/app.css`: it adds the Masu style sheet, and the Sumi theme
  import as a comment.

It does not add what a file already has, so you can run it again. When it
cannot find the `new LiveSocket(...)` call, or its `hooks` are not an
object or a variable, it changes nothing in `app.js` and prints the lines
to add.

## 3. Import the components

In the `html_helpers` of your web module (`lib/my_app_web.ex`):

```elixir
import Masu.Components
```

## 4. A grid of a list

```elixir
defmodule MyAppWeb.UserLive.Index do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, users: Accounts.list_users())}
  end

  def render(assigns) do
    ~H"""
    <.data_grid id="users" rows={@users} label="Users" searchable>
      <:col field={:name} />
      <:col field={:email} />
      <:col field={:inserted_at} type={:datetime} label="Joined" />
    </.data_grid>
    """
  end
end
```

The grid shows the first rows at once, rendered on the server. A click
on a header sorts by it, the search box finds rows by their text, and
the arrow keys move between the cells.

## 5. A grid of a table

For a table of many rows, give the grid an Ecto query and the repo
instead of the rows:

```heex
<.data_grid
  id="orders"
  source={from(o in Order, where: o.shop_id == ^@shop.id)}
  repo={MyApp.Repo}
  label="Orders"
  sort={[{:placed_at, :desc}]}
>
  <:col field={:number} width={120} />
  <:col field={:customer} />
  <:col :let={order} field={:status} type={:enum}>
    <.badge status={order.status} />
  </:col>
  <:col field={:total} type={:decimal} />
  <:col field={:placed_at} type={:datetime} label="Placed" />
</.data_grid>
```

Now the database sorts, searches and counts, and the LiveView reads only
the rows the person scrolls to: a hundred at a time, each block with a
`LIMIT`, after the last row of the block before it. See [Sources](sources.md) for what the query may have, and the
indexes that make it fast.

## 6. Test it

```elixir
import Masu.Test

test "lists the newest orders first", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/orders")

  assert [%{"number" => "A-1042"} | _] = rows(view, "orders")
  assert total(view |> search("orders", "acme"), "orders") == 3
end
```

See [Testing](testing.md).
