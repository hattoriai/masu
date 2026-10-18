# Actions

Every app has its own things to do with rows: archive them, assign
them, send an invoice again, open one in another page. A grid offers
them where the person works, rather than in buttons built around it:
on the rows selected, and on each row.

```heex
<.data_grid id="orders" source={Order} repo={Repo} selectable scope={@current_scope}>
  <:col field={:number} />
  <:col field={:customer} />
  <:col field={:status} type={:enum} />

  <:action label="Archive" on_action={&OrdersGrid.archive/1} />
  <:action :if={@admin?} label="Delete" on_action={&OrdersGrid.delete/1}
    confirm="Delete {count} orders?" danger />

  <:row_action label="Open" navigate={&~p"/orders/#{&1}"} />
  <:row_action label="Send again" on_action={&OrdersGrid.resend/1}
    disabled={&(&1.status == "draft")} />
</.data_grid>
```

```elixir
defmodule MyAppWeb.OrdersGrid do
  alias MyApp.Orders

  def archive(%{selected: selected, scope: scope}) do
    {count, _} = Orders.archive(scope, selected)
    {:ok, "#{count} orders archived"}
  end

  def resend(%{row: order, scope: scope}) do
    case Orders.resend_invoice(scope, order) do
      {:ok, _} -> {:ok, "Invoice sent again"}
      {:error, reason} -> {:error, "Not sent: #{reason}"}
    end
  end
end
```

## On the rows selected: `:action`

With `selectable`, the bar above the grid shows the actions while rows
are selected: "4 selected · Archive · Delete · Clear".

The action's context has `selected`, the rows as `Masu.Live.selected/1`
gives them, and `count`:

* `{:ids, ids}` - the rows the person ticked;
* `{:query, query}` - every row of the query (the box in the header),
  for an Ecto source: an `Ecto.Query` with the person's filters and
  search, less the rows they took out of it. An action on a million rows
  is one statement:

```elixir
def archive(%{selected: {:query, query}}), do: Repo.update_all(query, set: [archived: true])
def archive(%{selected: {:ids, ids}}), do: Repo.update_all(where(Order, [o], o.id in ^ids), set: [archived: true])
```

When the action is done, the grid reads its rows again (they may have
changed) and clears the selection; `keep_selection` keeps it. A failed
action keeps it, so the person can try again.

## On a row: `:row_action`

Each row has a button at its end (a column of its own, stuck to the end
as a pinned one) that opens the menu of its actions. A right click on a
row, and the context-menu key or Shift+F10 on its active cell, open them
too, after the cell's own items (`cell_menu`, `:cell_action`). The menu
is an ARIA menu: the arrows move, Enter runs, Escape closes.

The action's context has `id` and `row`, the row as the source reads it
now (not the browser's copy).

* `navigate` and `patch`, functions of the row that give a path, make
  the item a link: LiveView follows it (`push_navigate` or
  `push_patch`), a middle click opens it in a tab, and the browser copies
  it as any link.
* `show`, a function of the row, says whether the row has the item.
* `disabled`, a function of the row (or a boolean), shows it unavailable:
  in the menu, not clickable.

The grid reads `show`, `disabled` and the link of each row as it sends
the row; the server reads them again, with the row from the source, when
the person runs the action.

### Other people on the row

With `Masu.Presence`, the context's `editors` are the people whose
editor is open on a cell of the row: an action may wait, or say so,
rather than change the row under them.

```elixir
def resend(%{editors: [person | _]}), do: {:error, "#{person.name} is editing this order."}
def resend(%{row: order}), do: ...
```

An action that changes rows of a grid with `live` broadcasts them, as
any change of your app does (`Masu.Live.broadcast_upsert/3`): the others
see them, with a flash.

## What an action does

| Attribute | |
| --- | --- |
| `on_action` | a function of the context, in the LiveView's process |
| `event` | the LiveView gets `{Masu.Action, name, context}` in `handle_info/2`, to change its assigns |
| `navigate`, `patch` | (`:row_action`) a link, of the row |
| `confirm` | a question first: "Delete {count} orders?" (`{count}` is the rows selected) |
| `danger` | it destroys: the button, and its question's answer, say so |
| `keep_selection` | (`:action`) the selection stays when it is done |
| `show`, `disabled` | (`:row_action`) of the row |

`:if` leaves an action out: `:if={@admin?}`. The server runs only the
actions the grid offers: one left out by `:if`, hidden or disabled for
the row, or with no rows selected, is refused, whatever the browser
sends.

## Results

`on_action` gives:

| | |
| --- | --- |
| `:ok` (or any other value) | done |
| `{:ok, message}` | done, and the grid says `message`, above it and to a screen reader |
| `{:error, message}` | failed: the grid says so |
| `:async` | it goes on in another process, which replies |

## Later: jobs and tasks

An action on 50,000 rows, or one that calls a slow service, goes on in
a job. Its context's `ref` reaches the grid from any process, on any
node of the cluster: the job says how far it is, and how it went.

```elixir
def export(context) do
  %{ref: context.ref, ids: ids(context.selected)}
  |> MyApp.Workers.Export.new()
  |> Oban.insert!()

  :async
end

# In the job:
def perform(%Oban.Job{args: %{"ref" => ref, "ids" => ids}}) do
  ids
  |> Enum.chunk_every(500)
  |> Enum.with_index(1)
  |> Enum.each(fn {chunk, i} ->
    MyApp.Export.run(chunk)
    Masu.progress(ref, min(i * 500, length(ids)), length(ids))
  end)

  Masu.reply(ref, {:ok, "#{length(ids)} orders exported"})
end
```

The grid shows the action running ("Export: running…", then "Export:
1,500 of 4,210"), and its reply: `:ok`, `{:ok, message}` or
`{:error, message}`. The rows are read again on `:ok`. If the person
left, the reply goes nowhere.

An action of the LiveView's own, which changes its assigns as it goes,
runs in a task of the LiveView:

```elixir
<:action label="Archive" on_action={&(send(self(), {:archive, &1}) && :async)} />

def handle_info({:archive, context}, socket) do
  {:noreply,
   start_async(socket, :archive, fn ->
     Orders.archive(context.scope, context.selected)
     Masu.reply(context.ref, {:ok, "#{context.count} archived"})
   end)}
end
```

## The scope

`scope` on the grid (your app's `@current_scope`, or the current user)
is in every action's context, and in every `Masu.Write` (see
[Editing](editing.md)): the grid is not where your app learns who acts.

## Testing

```elixir
select(view, "orders", [1, 2])
assert actions(view, "orders", :selection) == ["Archive"]
assert action(view, "orders", "Archive") == {:ok, "2 orders archived"}

assert actions(view, "orders", :row, 1) == ["Open", "Send again"]
assert row_action(view, "orders", "Open", 1) == {:navigate, "/orders/1"}
assert row_action(view, "orders", "Send again", 3) == {:error, :refused}
```

`action/3` and `row_action/4` send what the browser sends, and the
server checks it as it does for a person: an action the grid does not
offer, or that is disabled for the row, is `{:error, :refused}`.
