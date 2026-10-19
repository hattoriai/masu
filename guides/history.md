# History

Undo and redo are each person's own, for as long as their page is open.
A grid with a `history` keeps the record across people and time: who
set this cell to 1,200, when, and what it was before; and brings a value
back.

```heex
<.data_grid id="orders" source={Order} repo={Repo} changeset={&Order.changeset/2}
  history={MyApp.GridHistory} user={@current_user}>
```

`history` is a store, a module of the `Masu.History` behaviour, and
`user` says who changes the cells (`:id` and `:name`).

## Where the history is kept

### In a table, of any repo

```elixir
defmodule MyApp.GridHistory do
  use Masu.History.Ecto, repo: MyApp.Repo
end
```

```sh
mix masu.gen.history
mix ecto.migrate
```

`mix masu.gen.history` writes the migration of the table, `masu_history`
(`--table` for another name, given to `use` as `table:` too). The table
runs on PostgreSQL, MySQL and SQLite: its values are a `:map` column,
which each adapter keeps its way.

The repo need not be the app's. A history in a database of its own (a
SQLite file next to the app's PostgreSQL, a database for audit) is a
repo of its own:

```elixir
defmodule MyApp.HistoryRepo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.GridHistory do
  use Masu.History.Ecto, repo: MyApp.HistoryRepo
end
```

```sh
mix masu.gen.history --migrations-path priv/history_repo/migrations
mix ecto.migrate --repo MyApp.HistoryRepo
```

### In the row's transaction, or after it

When the history is in the grid's own repo, a change and its record are
saved in one transaction: both, or neither. A record that fails takes
its change back, and the cell says so ("Not saved: the history could not
keep it.").

In a repo of its own, no transaction spans the two databases: a change is
recorded just after it saves. A node that stops between the two leaves
the change unrecorded, and a record that fails is logged; a change that
did not save is never recorded. Keep the history in the main repo when
every change must have its record.

### Your own store

An app that already audits (an audit table, PaperTrail, ExAudit, a
service) implements `Masu.History` over it: `record/1`, `for_cell/4`,
`for_row/3`, `recent/2`, `batch/2`, `entry/2`, and `repo/0` when it
keeps its records in an Ecto repo. `Masu.History.Memory` keeps them in
memory, for development and tests.

## What is recorded

Every write of the grid that saves (see [Editing](editing.md)): a cell
typed in, pasted, filled, emptied, undone or restored is an entry of its
cell, with its value before and after (as the browser gets them, see
`Masu.Wire`), who (`user`), when, and what they did (`origin`). A new row
and a row deleted are entries of the row. The entries of one write share
a batch: a paste of 200 cells is one batch.

The grid records its own saves and your `on_update`'s alike. An
`on_update` that saves in a transaction of its own records in it with
`Masu.Write.record/3`, and the grid does not record the change again:

```elixir
def update(write) do
  Enum.reduce(write.changes, write, fn change, write ->
    {:ok, write} =
      Repo.transaction(fn ->
        order = Orders.update!(change.row, change.params)
        write |> Masu.Write.ok(change, order) |> Masu.Write.record(change, order)
      end)

    write
  end)
end
```

What your app changes another way (an action's `Repo.update_all`, a job,
an import) it records with `Masu.History.record/2`:

```elixir
Masu.History.record(MyApp.GridHistory, [
  %{grid: "orders", row_id: order.id, key: :status, before: "paid", after: "archived",
    origin: :archive, user: user}
])
```

A write saved later (`Masu.Write.async/1`) is the job's to record, as it
saves.

## Seeing it

A right click on a cell (or the context-menu key, or Shift+F10) has
**History**, the cell's, and **Row history**, its row's; Ctrl+Alt+H opens
the active cell's. The popover lists the values, newest first: "1,210
was 1,180", who set it and when ("Grace · 2 minutes ago"), and what they
did, when it was not typing (pasted, filled, restored). It is a dialog;
Escape closes it, and the focus goes back to the grid.

## Bringing a value back

**Restore 1,180** sets the cell to the value it had before that change:
an edit, through your changeset and the read-only rules as any, recorded
as a restore. It is refused when someone changed the cell since the
history was read ("Changed by someone else meanwhile.").

**Undo all 200**, on an entry of a batch of several cells, sets every
cell of the batch back: someone's paste undone at once. A cell that
changed since the batch keeps its value, with the refusal on it; the
others go back.

## Testing

```elixir
assert edit(view, "orders", [{1, :total, "11.50"}]) == :ok

assert [%{before: "10.00", after: "11.50", user: "Ada", origin: "test"} = entry] =
         history(view, "orders", 1, :total)

assert history(view, "orders", 1) == [entry]   # the row's
assert restore(view, "orders", entry.id) == {:ok, 1}
assert {:ok, _count} = restore(view, "orders", {:batch, entry.batch})
```

Start `Masu.History.Memory` in `test_helper.exs` for a grid whose
history is in memory, and `Masu.History.Memory.clear/0` between tests.
