# Menus of your own

An app adds its own items to the grid's menus, rather than build menus
around the grid: items in the header menu of a column, and a menu on
each cell. Each item runs a function of yours, sends your LiveView an
event, runs a JS command, or opens a panel that your LiveView renders.

```heex
<.data_grid id="orders" source={Order} repo={Repo} cell_menu>
  <:col field={:number} />
  <:col field={:customer} />
  <:col field={:status} type={:enum} />
  <:col field={:total} type={:decimal} />

  <:header_action label="Explain" on_action={&explain/1} />
  <:header_action :let={action} label="Column stats" types={[:integer, :decimal]}>
    <.column_stats column={action.column} />
  </:header_action>

  <:cell_action label="Open the order" event="open_order" />
  <:cell_action label="Copy a link" js={JS.dispatch("app:copy-link")} />
  <:cell_action :let={action} label="Customer card" columns={[:customer]}>
    <.customer_card name={action.value} />
  </:cell_action>
</.data_grid>
```

Nothing of this is on unless the grid says so: a grid with no
`cell_menu` and no `:cell_action` leaves the browser's own menu on a
right click, and its header menus are the filters alone.

## The menu of a cell

A right click on a cell opens its menu, and so does the context-menu
key, or Shift+F10, on the active cell. A right click in a range that is
selected keeps the range: the menu is for it.

`cell_menu` gives the menu the grid's own items:

| Item | Does |
| --- | --- |
| Copy | copies the cell, or the range it is in, as Ctrl+C does |
| Copy with headers | the same, with the labels of the columns first |
| Filter by *value* | the rows with the cell's value in its column (an enum's: that value ticked) |
| Exclude *value* | the rows without it |
| Filter by empty, by not empty | the rows with no value in the column, or with one |
| Sort ascending, descending | sorts by the column |

The filters are for a column that filters (and a cell of your own HEEx
only when it edits, so that the browser has its value), the sorts for
one that sorts. `cell_menu={[:copy, :sort]}` keeps some of them: `:copy`,
`:filter` and `:sort`. The `:cell_action` items come after them; a grid
with them and no `cell_menu` has those alone.

A group's row, and a new row that is not saved yet, have no menu.

## The items

`:header_action` and `:cell_action` take the same attributes:

* `label` - the item's text;
* `on_action` - a function of the item's context, called in the
  LiveView's process;
* `event` - a name: the LiveView gets `{Masu.Action, name, context}` in
  `handle_info/2`, to change its assigns;
* `js` - a `Phoenix.LiveView.JS` command, run in the browser on the
  grid's element;
* content - a panel, which the server renders with the context;
* `columns` and `types` - the keys or the types of the columns the item
  is for; and `show`, a function of the `Masu.Column` that says so.

An item does one or more of them. `:if` leaves an item out:
`:if={@admin?}`.

```elixir
def handle_info({Masu.Action, "open_order", %{id: id}}, socket) do
  {:noreply, push_navigate(socket, to: ~p"/orders/#{id}")}
end
```

### The context

The function, the event and the panel get a map:

| Key | |
| --- | --- |
| `grid` | the grid's id |
| `column` | the column's key |
| `id` | the row's id (a cell) |
| `row` | the row, as the source reads it (a cell) |
| `value` | the cell's value (a cell) |
| `range` | `%{ids: ids, columns: keys}` when the cell is in a range of several cells: the rows' ids (up to 10,000) and the columns' keys; else `nil` |

The row and the value are read on the server, from the source, by the
row's id: the browser says where the person clicked, not what is there.
A row that is gone (deleted meanwhile) runs nothing. The ids of a range
are the browser's, as it has them: an item that acts on them checks
them, as it checks any params (that the person may change those rows).

### In the browser

An item with `js` runs its command on the grid's element. Before it, the
element gets a `masu:action` event, whose `detail` is the context as the
browser has it: `grid`, `kind` (`"header"` or `"cell"`), `action` (the
label), `column`, and for a cell `id`, `value` (as the browser has it:
a decimal or a date as text) and `range`. The event bubbles: a hook of
yours, or a listener on the page, reads it:

```javascript
window.addEventListener("masu:action", ({ detail }) => {
  if (detail.action === "Copy a link") {
    navigator.clipboard.writeText(`${location.origin}/orders/${detail.id}`)
  }
})
```

### Panels

An item with content opens a panel: the server renders the content
with the context (`:let`), and the browser places it under the header
or the cell, as a dialog, with the focus in it. Escape, or a click away,
closes it, and the focus goes back to the grid. One panel is open at a
time.

The content is any HEEx: a summary of the column, a card of the row, a
form. Its events go to your LiveView, as any other:

```heex
<:cell_action :let={action} label="Notes" columns={[:customer]}>
  <.form for={%{}} phx-submit="save_note">
    <input type="hidden" name="id" value={action.id} />
    <textarea name="note"></textarea>
    <button>Save</button>
  </.form>
</:cell_action>
```

Until Masu shows a column's distribution itself, a panel is the place
for the stats of a column: a histogram, the top values.

## Header menus

The `:header_action` items are at the top of each column's header menu,
above Group by and the filter. A column that does not filter, and has
items, gets a menu of its items (the three dots in its header). In a
grid with header items, a right click on a header opens its menu too.

## On the server

The server runs only the items that the grid offers: an item of the
grid, for that column, whose label is the one the person saw (the items
of a LiveView change with `:if`). Anything else is refused, and the
browser says that the item no longer applies.

## Accessibility

The menu of a cell is an ARIA `menu` of `menuitem`s: ↑ and ↓ move
between them, Home and End go to the first and the last, a letter to
the next that starts with it, Enter or Space runs one, and Escape or Tab
closes it, with the focus back on the grid. A panel is a `dialog` named
by its item.

## Testing

`Masu.Test` runs the items as the browser does, through the server:

```elixir
assert actions(view, "orders", :cell, :customer) == ["Open the order", "Customer card"]

view
|> cell_action("orders", "Open the order", :number, 42)

header_action(view, "orders", "Column stats", :total)
assert render(view) =~ "Lowest"
close_panel(view, "orders")
```

`cell_action/6` takes a range with `range: {ids, keys}`. An item that
is only a JS command runs in the browser, not in a test.
