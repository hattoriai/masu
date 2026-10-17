# Trees and details

Rows that hold other rows: a tree, whose children have the columns of
their parent, and details, where a row opens on anything of its own,
another grid too. HTML tables cannot nest rows; a grid of `<div>`s that
draws every nested row freezes the browser at twenty thousand of them.
Masu does neither: a tree is a list of the rows that are open, read a
block at a time, and a detail is rendered by the server under its row.

## Trees

```heex
<.data_grid id="accounts" rows={@accounts} tree={:parent_id}>
  <:col field={:name} />
  <:col field={:balance} type={:decimal} />
</.data_grid>
```

`tree` names the field of a row that holds its parent's id (a function
of the row, for a list). A row whose parent is `nil`, or not among the
rows, is a root. `expanded={[1, 7]}` starts rows open.

The first column of each row is indented by its level, with an arrow:

| Key or click | Does |
| --- | --- |
| The arrow, → on the first column | opens the row: its children show under it |
| The arrow, ← on the first column | closes the row; on a row without children, goes to its parent |
| `*` on the first column | opens every row beside it that has children |

The grid is a `treegrid`, and each row has `aria-level`,
`aria-setsize`, `aria-posinset`, and `aria-expanded` when it has
children.

**Sorting** sorts each row's children among themselves. **A filter or a
search** keeps the rows that match and their ancestors, open, so that a
match always shows under its parents; the person may close them, and a
new filter opens them again. The rows the person opened stay open as
they sort and filter.

**Live rows** (`Masu.Live`) take their place in the tree, under their
parent, and the rows of a tree edit as any others.

### The sources of a tree

* **A list** (`Masu.Source.List`) holds every row, and works out the rows
  that show in the LiveView: a tree of twenty thousand rows opens and
  sorts in a few milliseconds.
* **An Ecto source** (`Masu.Source.Ecto`, `tree={:parent_id}` naming a
  field) keeps the ids of the rows that show, not the rows: the roots,
  in the grid's order, and the children of each open row, read when it
  opens (a level a query). Each block of rows is read by its ids. A
  filter reads the ids of the rows that match and climbs to their
  ancestors, a level a query. The schema needs one primary key.
* **A source of your own** implements `c:Masu.Source.nodes/3` (the rows
  of a block, each with its place in the tree, `t:Masu.Tree.node_info/0`)
  and `c:Masu.Source.siblings/2` (for `*`), and reads the rows the person
  opened from `Masu.Query`'s `expanded`. `Masu.Tree` has the helpers the
  two sources use.

## Details

```heex
<.data_grid id="orders" source={Order} repo={Repo}>
  <:col field={:number} />
  <:col field={:customer} />
  <:detail :let={order}>
    <p>{order.customer} ordered {length(order.lines)} lines.</p>
    <.data_grid id={"lines-#{order.id}"} rows={order.lines} height="12rem">
      <:col field={:product} />
      <:col field={:quantity} type={:integer} />
    </.data_grid>
  </:detail>
</.data_grid>
```

With a `:detail` slot, each row's first cell has an arrow that opens the
row's detail under it: the slot, rendered by the server for the row, as
wide as the screen, as tall as its content. The rows under it move down;
the rows themselves stay one height, so the grid still scrolls a block
at a time, however many rows it has.

| Key or click | Does |
| --- | --- |
| The arrow, Alt+→ | opens the row's detail |
| The arrow, Alt+← | closes it |
| Alt+↓ | goes into the open detail: its grid, or its first control |
| Escape in a detail | comes back to its row |

A detail is a `region`, named by the `detail` message ("Details"); the
grid says "Details shown" and "Details hidden".

A detail is any HEEx: a component of your own, a form, another
`data_grid` (give each an id of its own). The keys and clicks inside a
detail are its own: the grid around it does not take them. A detail
follows its row as the person sorts, and hides while a filter leaves the
row out. Fifty details are open at most; opening one more closes the
first.

## Testing

`Masu.Test.expand/3`, `collapse/3` and `expand_siblings/3` open and close
rows of a tree, and `Masu.Test.nodes/3` reads where each row is.
`Masu.Test.detail/4` opens a row's detail; `Phoenix.LiveViewTest.render/1`
then has it, and a grid in it is read as any other.
