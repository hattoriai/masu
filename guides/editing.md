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

## What a person may edit

* A column edits when the grid has a `changeset` (or an `update`), the
  column names a field, and it does not say `editable={false}`. A column
  of a `value` function does not edit.
* A row is found again on the server by its id, among the rows of the
  grid's own query: for an Ecto source, through the query you gave the
  grid, so that no one edits a row the grid would not show them. The
  columns that do not edit take no value, whatever the browser sends.
* The changeset decides the rest, as for any form: `cast/3` takes only
  the fields you list.

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

## Live rows

With `live`, a saved row is broadcast on the grid's topic: the other
people who have the grid open see it, with a flash (see
[Live rows](live.md)).

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

A cell shows its new value at once, and the old one again if the server
refuses it. A paste, a fill or an emptied range is one batch, saved row by
row, with the errors on their cells, and one undo.

The editors follow the column's type: text, numbers read in the grid's
locale ("1.234,5" in German), the browser's date, datetime and time
inputs.

## Testing

```elixir
assert :ok = edit(view, "orders", [{1, "total", "11.50"}])
assert {:error, [{1, "status", "is invalid"}]} = edit(view, "orders", [{1, "status", "lost"}])
```
