# Live rows

A grid can follow a PubSub topic, and show the rows that change on it as
they change: a new order comes in, a status changes, a row is deleted,
and every person who has the grid open sees it, in the place of their
own order, filters and search.

## 1. Add the hook

The LiveView process subscribes to the topic, and `Masu.Live` takes the
changes from its `handle_info`. Add the hook to the LiveView:

```elixir
on_mount Masu.Live
```

or to the `live_session` of its routes:

```elixir
live_session :default, on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}, Masu.Live] do
```

A grid with `live` in a LiveView without the hook raises, and says so.

## 2. Follow a topic

```heex
<.data_grid id="orders" source={Order} repo={Repo} live={{MyApp.PubSub, "orders"}}>
```

## 3. Broadcast the changes

Where the rows change, broadcast them:

```elixir
def update_order(order, attrs) do
  with {:ok, order} <- order |> Order.changeset(attrs) |> Repo.update() do
    Masu.Live.broadcast_upsert(MyApp.PubSub, "orders", order)
    {:ok, order}
  end
end

def delete_order(order) do
  with {:ok, order} <- Repo.delete(order) do
    Masu.Live.broadcast_delete(MyApp.PubSub, "orders", order)
    {:ok, order}
  end
end
```

`broadcast_upsert/3` is for a row inserted or changed;
`broadcast_delete/3` takes the row or its id.

## What the grid does

* A grid of an Ecto source asks its query again: the count, and the
  rows on the screen. The database is the truth, so the broadcast row
  only says that something changed; a change that a person's filters
  leave out does not show.
* A grid of a list puts the row in its copy of the list, in the place of
  the row with its id or at the end, or takes it out, then applies the
  person's query again.
* The browser keeps the person's place: the scroll does not move, and
  the rows on the screen stay until their new values come, so the grid
  does not blink. Each changed row flashes for a moment
  (`.masu-changed`, see [Theming](theming.md)).
* Changes that come together make one new set of rows: the grid takes
  every change that waits in the LiveView's mailbox at once, so a batch of
  a thousand updates is one query, not a thousand.

## A list and its LiveView

A grid of a list keeps the changes in its own copy of the list; the
LiveView's assign does not change. Give the grid new `rows`, or broadcast
changes, not both: new `rows` replace the grid's copy.

## Testing

`Masu.Test` waits for the LiveView to take the changes broadcast before
a call:

```elixir
test "shows a new order", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/orders")
  {:ok, order} = Orders.create_order(%{number: "A-1043"})

  Masu.Live.broadcast_upsert(MyApp.PubSub, "orders", order)
  assert total(view, "orders") == 121
end
```
