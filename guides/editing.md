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
| `update`, with any source | whatever your function does: a context function, an API, a cache |

`update` is the place to plug in your own persistence, and `on_save`
the place to hear about what was saved (below).

## What a person may edit

* A column edits when the grid has a `changeset` (or an `update`), the
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

## Telling the LiveView: `on_save`

`on_save` is called with the rows that an edit saved (a batch, for a
paste or a fill), in the LiveView's process, after they are saved and
not when the server refuses them:

```heex
<.data_grid id="orders" source={Order} repo={Repo} changeset={&Order.changeset/2}
  on_save={&Audit.log_changes(@current_user, &1)}>
```

A component cannot change its LiveView's assigns, but the function runs
in the LiveView's process: a message to `self()` reaches its
`handle_info`, which can.

```heex
<.data_grid id="users" rows={@users} changeset={&User.changeset/2} on_save={&send(self(), {:saved, &1})}>
```

```elixir
def handle_info({:saved, rows}, socket) do
  saved = Map.new(rows, &{&1.id, &1})
  {:noreply, update(socket, :users, fn users -> Enum.map(users, &Map.get(saved, &1.id, &1)) end)}
end
```

New `rows` from the LiveView replace the grid's copy, and keep the
person's order, filters and search.

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

With [Collaboration](collaboration.md), a cell someone types in is
locked for the others, so two people rarely type in one cell; the
compare-and-swap is what holds when they do.

An `update` function gets the row as it was compared; to save it with
the same guarantee, save it in a transaction of your own, or with
`optimistic_lock/3`.

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

## Saving your own way

`update` takes the place of `changeset`, for a context function, an API,
or rows that are not in a repo:

```heex
<.data_grid id="orders" source={Order} repo={Repo} update={&Orders.update_order/2}>
```

It gets the row and the params, and gives `{:ok, row}`, or
`{:error, changeset}` (its errors go on the cells), or
`{:error, message}` (the message goes on every edited cell of the row).

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
must have an id: `struct={fn -> %{id: next_id(), ...} end}`). `create`
takes the place of both, as `update` does for edits:

```heex
<.data_grid id="tasks" source={Task} repo={Repo} create={&Tasks.create_task/1}>
```

It gives `{:ok, row}`, `{:error, changeset}` or `{:error, message}`.

Below the last row of the grid, a row says "+ New row": a click, Enter
on it, or Ctrl+Enter (or Insert) anywhere adds a new row there, a draft
that the person fills as any row. A draft is the person's own: it is
not saved, nor shown to others, until they leave it (another row, or out
of the grid), or press Ctrl+Enter for the next one. Then it saves; its
errors go on its cells, and it stays a draft until they are right.
Escape lets a draft go. A saved row takes its place in the person's
order, with a flash; a row that the filters leave out says so.

A new row takes values in the columns that edit (`editable={false}` and
columns of a `value` function do not). `on_save` hears of new rows too.

A paste of more lines than there are rows below asks to add the rest as
new rows, saved at once: those the server refuses stay as drafts, with
their errors, and the grid goes to the first of them.

## Deleting rows

`deletable` deletes rows with the repo of an Ecto source (`Repo.delete`,
in a transaction that locks the row), or from a list; a function of the
row says which rows delete. `delete` takes the place of the repo:

```heex
<.data_grid id="tasks" source={Task} repo={Repo} deletable={&(&1.status != :done)}>
<.data_grid id="tasks" source={Task} repo={Repo} delete={&Tasks.delete_task/1}>
```

`delete` gives `:ok`, `{:ok, row}` or `{:error, reason}`. A row is found
through the grid's own query, so a person deletes only the rows they
may see.

Ctrl+Delete (⌘⌫) deletes the rows of the selection, or of the active
cell, or, with `selectable`, the rows selected (Delete in the bar above
the grid), after a question: "Delete 3 rows?". Ctrl+Z brings them back:
the grid keeps the last deletes' rows, and inserts them again (for a
list, in their places). A grid with `delete` brings them back with
`restore`, a function of a deleted row; without it, a delete is not
undone. `on_delete` hears of the rows deleted. At most 1,000 rows are
added or deleted at once.

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

assert {:ok, [id]} = add_rows(view, "tasks", %{title: "Write docs"})
assert {:ok, undo} = delete_rows(view, "tasks", [id])
assert {:ok, [^id]} = restore_rows(view, "tasks", undo)
```
