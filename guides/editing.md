# Editing

A grid with a `changeset` lets the person edit its cells, as in a
spreadsheet, and saves each edit through your changeset:

```heex
<.data_grid id="orders" source={Order} repo={Repo} changeset={&Order.changeset/2}>
  <:col field={:number} editable={false} />
  <:col field={:customer} />
  <:col field={:status} type={:enum} />
  <:col field={:total} type={:decimal} />
</.data_grid>
```

An edit runs `row |> Order.changeset(params) |> Repo.update()`. The
params are the edited columns' fields, as strings, with the values the
browser sends (`%{"total" => "11.50"}`), so the changeset casts and
checks them as it does a form's.

## Where an edit is saved

| The grid has | An edit |
| --- | --- |
| an Ecto source and `changeset` | `Repo.update/2` of the changeset: the database row changes |
| a list and `changeset` | the changeset applied in memory: the grid's copy of the row changes, and nothing else; your LiveView's assign and your database do not |
| `on_update`, with any source | whatever your function does with the `Masu.Write`: a context function, an `Ecto.Multi`, an API, a job (below) |

## Writes of your own: `Masu.Write`

Every change a person makes to the rows is a `Masu.Write`: the cells of
an edit (one typed, a paste of 500 rows, a fill, an undo), new rows,
rows deleted, rows brought back. The grid builds it, and gives it to
your function for it, which saves it and gives it back with a result for
each change:

| Attribute | Gets a write of | Without it |
| --- | --- | --- |
| `on_update` | cells edited, a `Masu.Write.Change` for each row | the grid's own way, with `changeset` |
| `on_create` | new rows | with `changeset` and `struct` |
| `on_delete` | rows to delete | `Repo.delete`, or out of a list (`deletable`) |
| `on_restore` | deleted rows, back (an undo) | inserted again, when the grid deletes its own way |

By the time your function gets the write, the grid has done its part:
each row is found again through the grid's own query, the cells that do
not edit, or that the row's state makes read-only, are refused, and so
are the cells someone changed meanwhile. A change has the row, the
params of the cells that are left (`%{"total" => "11.50"}`), their keys,
and the values the person saw. The write has the batch's `origin` (what
the person did: `:edit`, `:paste`, `:fill`, `:clear`, `:undo`...), the
grid's `scope`, and a `ref`.

```heex
<.data_grid id="orders" source={Order} repo={Repo} scope={@current_scope}
  on_update={&OrdersGrid.update/1} on_delete={&OrdersGrid.delete/1}>
```

Row by row, through a context function:

```elixir
def update(write) do
  Masu.Write.each(write, &Orders.update_order(write.scope, &1.row, &1.params))
end
```

A batch at once, in one transaction that touches other records too, and
saves all of it or none:

```elixir
def update(write) do
  Masu.Write.all(write, fn changes ->
    changes
    |> Enum.reduce(Ecto.Multi.new(), fn change, multi ->
      multi
      |> Ecto.Multi.update({:order, change.index}, Order.changeset(change.row, change.params))
      |> Ecto.Multi.insert({:audit, change.index}, Audit.entry(write.scope, change))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, done} -> {:ok, for(change <- changes, do: done[{:order, change.index}])}
      {:error, {:order, index}, changeset, _done} -> {:error, Enum.at(changes, index), changeset}
    end
  end)
end
```

The grid's own way, and more:

```elixir
def update(write) do
  write
  |> Masu.Write.save()
  |> tap(&Audit.log(&1.scope, Masu.Write.saved(&1)))
end

# A paste its own way; the rest the grid's.
def update(%Masu.Write{origin: :paste} = write), do: Masu.Write.all(write, &Orders.import(write.scope, &1))
def update(write), do: Masu.Write.save(write)
```

A result is `{:ok, row}`, with the row as saved, or `{:error, reason}`:
an `Ecto.Changeset` (its errors go on the cells of their fields), a
message (on every cell of the row), or `[{key, message}]`. A change left
without a result is a mistake, and the grid raises.

A component cannot change its LiveView's assigns, but your function runs
in the LiveView's process: a message to `self()` reaches its
`handle_info`, which can.

```elixir
def update(write) do
  write = Masu.Write.save(write)
  send(self(), {:saved, Masu.Write.saved(write)})
  write
end

def handle_info({:saved, rows}, socket) do
  saved = Map.new(rows, &{&1.id, &1})
  {:noreply, update(socket, :users, fn users -> Enum.map(users, &Map.get(saved, &1.id, &1)) end)}
end
```

New `rows` from the LiveView replace the grid's copy, and keep the
person's order, filters and search.

### Later: a job

A write may be saved by a job: a paste into a system that takes its
time, rows that go through a queue. `Masu.Write.async/1` says that the
changes without a result are saved later; the write's `ref` reaches the
grid from any process, on any node:

```elixir
def update(write) do
  changes = Enum.map(write.changes, &%{id: &1.id, params: &1.params})
  Oban.insert!(MyApp.Workers.SaveCells.new(%{ref: write.ref, changes: changes}))
  Masu.Write.async(write)
end

# In the job:
Masu.reply(ref, :ok)
Masu.reply(ref, {:error, "The ledger is closed."})
```

The cells show saving until the reply. Then the grid reads its rows
again; an error refuses the cells, which show their old values, with
the message. Deletes may go on later too; new rows and rows brought back
need their ids at once, and cannot.

## What a person may edit

* A column edits when the grid has a `changeset` (or an `on_update`), the
  column names a field, and it does not say `editable={false}`. A column
  of a `value` function does not edit.
* A row, or a cell, may be read-only by its state: see below.
* A row is found again on the server by its id, among the rows of the
  grid's own query: for an Ecto source, through the query you gave the
  grid, so that no one edits a row the grid would not show them. The
  columns that do not edit take no value, whatever the browser sends.
* The changeset decides the rest, as for any form: `cast/3` takes only
  the fields you list.

## Read-only rows and cells

A row's state can make its cells read-only: an invoice that is paid, a
total that edits only while the order is a draft.

```heex
<.data_grid id="invoices" source={Invoice} repo={Repo} changeset={&Invoice.changeset/2}
  row_editable={&(&1.status != "paid")}>
  <:col field={:customer} />
  <:col field={:total} type={:decimal} editable={&(&1.status == "draft")} />
</.data_grid>
```

* `row_editable` on the grid: a function of the row; `false` makes every
  cell of the row read-only.
* `editable` on a column: `false`, or a function of the row that says
  whether the row's cell edits.

The server decides, with the row it finds again for the edit (not the
one the browser had): an edit of a read-only cell is refused with "This
cell cannot be edited.", and the row's other edits are saved. The browser
gets each row's read-only cells with the row: they open no editor, show
muted, have `aria-readonly="true"`, and a paste, a fill or Delete passes
them by.

## Two people, one cell

Each edit carries the value the person saw: the value of the cell when
its editor opened (or, for a paste or a fill, when they pasted). The
server compares it with the cell's value now, by the column's type
(`120.50` is `120.5`), and refuses the edit if someone changed the cell
meanwhile: "Changed by Ada meanwhile." (the name of who saved the row,
when the grid has a `live` topic and they had a `user`; "Changed by
someone else meanwhile." otherwise). The cell then shows its
value now, and the person decides again. It is the optimistic
concurrency of a database, a compare-and-swap of each cell: two people
who edit different cells of one row both save.

For an Ecto source, the row is read, compared and saved in one
transaction that locks it (`SELECT ... FOR UPDATE` on PostgreSQL and
MySQL; SQLite writes one transaction at a time), so two saves cannot both
pass the comparison. A schema with `Ecto.Changeset.optimistic_lock/3`
refuses a row whose version changed, with the same message.

With [Collaboration](collaboration.md) (optional, with Issho), a cell someone types in is
locked for the others, so two people rarely type in one cell; the
compare-and-swap is what holds when they do.

An `on_update` gets the rows as they were compared, read again but not
locked. `Masu.Write.save/1` reads, compares and saves each row again in
a transaction that locks it; to save your own way with the same
guarantee, save in a transaction of your own that locks the row, or
with `optimistic_lock/3`.

## Errors

A changeset with errors saves nothing of the row. Each error goes on the
cell of its field, which shows its old value again, with a red line and
the error as its title; a screen reader hears the first one. The other
cells that the person edited in the row say that they were not saved.

The error stays on the cell until the person edits it again.

## A grid of a list

A grid of a list applies the changeset to its row in memory
(`Ecto.Changeset.apply_action/2`) and puts the new row in its copy of the
list. A schemaless changeset works for rows that are maps:

```elixir
def changeset(person, params) do
  types = %{name: :string, age: :integer}

  {person, types}
  |> Ecto.Changeset.cast(params, Map.keys(types))
  |> Ecto.Changeset.validate_required([:name])
end
```

## New rows

A grid adds rows with `create`, a function of the params, or with its
`changeset` and a `struct`, the row a new one starts from:

```heex
<.data_grid
  id="tasks"
  source={Task}
  repo={Repo}
  changeset={&Task.changeset/2}
  struct={%Task{status: :todo}}
>
```

The changeset casts the new row's params into the struct, and the repo
inserts it (for a list, `apply_action(changeset, :insert)`, and the row
must have an id: `struct={fn -> %{id: next_id(), ...} end}`). `on_create`
takes the place of both, as `on_update` does for edits:

```heex
<.data_grid id="tasks" source={Task} repo={Repo} on_create={&TasksGrid.create/1}>
```

```elixir
def create(write), do: Masu.Write.each(write, &Tasks.create_task(write.scope, &1.params))
```

Below the last row of the grid, a row says "+ New row": a click, Enter
on it, or Ctrl+Enter (or Insert) anywhere adds a new row there, a draft
that the person fills as any row. A draft is the person's own: it is
not saved, nor shown to others, until they leave it (another row, or out
of the grid), or press Ctrl+Enter for the next one. Then it saves; its
errors go on its cells, and it stays a draft until they are right.
Escape lets a draft go. A saved row takes its place in the person's
order, with a flash; a row that the filters leave out says so.

A new row takes values in the columns that edit (`editable={false}` and
columns of a `value` function do not).

### Fields of the person's own: `create_with`

The grid puts nothing of the person's on a new row by itself. In an app
of many accounts, give it `create_with`, the fields every new row gets:

```heex
<.data_grid
  id="tasks"
  source={@tasks}
  repo={Repo}
  changeset={&Task.changeset/2}
  struct={%Task{status: :todo}}
  create_with={[account_id: @current_scope.account.id]}
>
```

Here `@tasks` is the account's tasks, `where(Task, account_id: ^id)`:
`create_with` is for new rows, and the `source` scopes what the grid
reads, edits and deletes. The grid puts them on the struct before the changeset (so its
validations see them) and on the changeset after it, over whatever it
cast: even a changeset that casts `account_id` cannot take another
account from the params. A column of one of these fields neither takes
a value on a new row nor edits. `on_create` saves your own way and
gets none of them: take the account from `write.scope` there.

A paste of more lines than there are rows below asks to add the rest as
new rows, saved at once: those the server refuses stay as drafts, with
their errors, and the grid goes to the first of them.

## Deleting rows

`deletable` deletes rows with the repo of an Ecto source (`Repo.delete`,
in a transaction that locks the row), or from a list; a function of the
row says which rows delete. `on_delete` takes the place of the repo:

```heex
<.data_grid id="tasks" source={Task} repo={Repo} deletable={&(&1.status != :done)}>
<.data_grid id="tasks" source={Task} repo={Repo} on_delete={&TasksGrid.delete/1}>
```

```elixir
# Soft deletes: the rows stay, archived.
def delete(write), do: Masu.Write.each(write, &Tasks.archive_task(write.scope, &1.row))
```

A result of a delete is `:ok` (or `{:ok, row}`) or `{:error, reason}`. A
row is found through the grid's own query, so a person deletes only the
rows they may see.

Ctrl+Delete (⌘⌫) deletes the rows of the selection, or of the active
cell, or, with `selectable`, the rows selected (Delete in the bar above
the grid), after a question: "Delete 3 rows?". Ctrl+Z brings them back:
the grid keeps the last deletes' rows, and inserts them again (for a
list, in their places). A grid with `on_delete` brings them back with
`on_restore`, a write of the deleted rows (`on_restore={&Masu.Write.save/1}`
when your `on_delete` deletes the grid's way too); without it, a delete
is not undone. At most 1,000 rows are added or deleted at once.

## Live rows

With `live`, a saved row is broadcast on the grid's topic, and a new or
deleted one too: the other people who have the grid open see it, with a
flash (see [Live rows](live.md)).

## What the person does

| | |
| --- | --- |
| Start | type on a cell (the text replaces its value), Enter or F2 (the value, to change), a double click |
| Save | Enter (then the cell below; Shift+Enter, above), Tab (then the cell to the right; Shift+Tab, to the left), a click elsewhere |
| Give up | Escape |
| A boolean | Space or Enter turns it |
| Empty | Delete or Backspace empties the editable cells of the selection |
| Fill down | Ctrl+D (⌘D) gives the selection's rows the values of its first |
| Paste | Ctrl+V (⌘V) puts tab-separated text, as a spreadsheet copies it, from the top left of the selection; one value fills the whole selection |
| Undo, redo | Ctrl+Z (⌘Z), and Ctrl+Shift+Z or Ctrl+Y |
| New row | Ctrl+Enter or Insert, or Enter on "+ New row" |
| Let a new row go | Escape on it |
| Delete rows | Ctrl+Delete (⌘⌫), after a question |

A cell shows its new value at once, and the old one again if the server
refuses it. A paste, a fill or an emptied range is one batch, saved row by
row, with the errors on their cells, and one undo.

The editors follow the column's type: text, numbers read in the grid's
locale ("1.234,5" in German), the browser's date, datetime and time
inputs, and for an enum a list of its values, which narrows as the
person types (↑ and ↓ pick, Enter takes). An enum's values are its
`values`, a schema's `Ecto.Enum` field's, or else those its rows have
(and then any value goes):

```heex
<:col field={:status} type={:enum} values={~w(todo doing done)} />
```

A value that the server would refuse does not go to it: text in a
number, a day that is not one, an enum's value that it does not have.
The editor stays, and says what is wrong; a paste puts the error on its
cell. Empty values are the changeset's to judge.

`decimals` shows a `:decimal` or `:number` column with that many digits,
whatever the value has: `decimals={2}` shows `3` as `3.00`.

## Testing

```elixir
assert :ok = edit(view, "orders", [{1, "total", "11.50"}])
assert {:error, [{1, "status", "is invalid"}]} = edit(view, "orders", [{1, "status", "lost"}])

# What the person did, as your on_update sees it.
assert :ok = edit(view, "orders", [{1, "total", "1"}, {2, "total", "2"}], origin: :paste)

# Saved later: the job replies.
assert :async = edit(view, "orders", [{1, "total", "11.50"}])

assert {:ok, [id]} = add_rows(view, "tasks", %{title: "Write docs"})
assert {:ok, undo} = delete_rows(view, "tasks", [id])
assert {:ok, [^id]} = restore_rows(view, "tasks", undo)
```
