# Accessibility

A grid follows the WAI-ARIA grid pattern.

## The name of a grid

Give each grid a name: `label="Orders"`, or `label_id` with the id of a
heading that names it. A screen reader says the name when the grid gets
the focus.

## The roles

* The scroll box has the `grid` role, `aria-rowcount` (every row of the
  query, and the header) and `aria-colcount`, and
  `aria-multiselectable`.
* The header is a `row` of `columnheader` cells; a column that sorts has
  `aria-sort` (`ascending` or `descending` on the first column of the
  order, `none` on the others).
* Each row has `aria-rowindex`, its place among all the rows, and each
  cell `aria-colindex`, so that a screen reader says "row 50,006 of
  100,001" for a row in the middle of a large grid, though only the rows
  on the screen are in the page.
* A selected cell has `aria-selected="true"`.
* A row that is coming from the server has `aria-busy="true"`.
* A tree's scroll box has the `treegrid` role, and each row `aria-level`,
  `aria-setsize` and `aria-posinset`, and `aria-expanded` when it has
  children (see [Trees and details](trees.md)).
* An open detail is a `region` named "Details"; Alt+↓ goes into it and
  Escape comes back to its row.

## The focus

The grid is one stop of the Tab key. The focus stays on the grid, and the
active cell is its `aria-activedescendant`: a screen reader follows the
cell as the arrows move it, while the rows come and go. See
[Keyboard and copy](keyboard.md) for the keys. In a grid whose rows open (`on_row_activate`), Enter
opens the row of the active cell, as a click on it does; see
[Actions](actions.md#opening-a-row-on_row_activate).

## The filter menu

A header's **⋯** is a button named for the column's menu ("Plan menu"),
with `aria-haspopup="dialog"` and `aria-expanded`; with `filter_bar={false}`,
the funnel of a column that filters is named "Filter" and the column's
label instead. The menu is a dialog with the same name; its sorts are
buttons with `aria-pressed` on the order the grid has; the focus goes to
the filter's first field (else to its first button), and comes back to the
header when it closes. An enum's values are a group of checkboxes.

Each chip is a button that opens its filter, named by its words ("Plan is
one of team, free"), and has a button that takes the filter away, named
for it. Add filter has `aria-haspopup="dialog"`; its menu of columns, and
the filter it opens, give the focus back to it when they close.

## The menu of a cell

In a grid with one (see [Menus of your own](menus.md)), the menu of a
cell is a `menu` named for its column, of `menuitem`s, with a
`separator` between its groups. It opens on the context-menu key or
Shift+F10, as on a right click; the focus goes to its first item. ↑ and
↓ move, Home and End go to the ends, a letter to the next item that
starts with it, Enter or Space runs an item, and Escape or Tab closes
it; the focus comes back to the grid, on the same cell. The panel of an
item is a `dialog` named by the item, with the focus in it, and Escape
closes it.

## Editing

The editor of a cell is an input named by its column's label, with the
focus while it is open; the focus comes back to the grid when it closes.
A cell the server refused has `aria-invalid="true"` and the error as its
title, and the live region says the error. In a column that edits, a cell
has `aria-readonly`: `"true"` when the row's state makes it read-only.

## Other people

The avatars are a group named by `messages["people"]` ("Also here"),
each with the person's name as its title and label. The lines and labels
of other people's cells are hidden from screen readers (they move as the
others move); a cell that another person edits says so when the person
tries to edit it.

## Announcements

A live region says how many rows a sort, a filter or a search gives
("9,412 rows"), how many rows were selected or copied, and why a query
was refused. Its words are in `messages`.

## Motion

Under `prefers-reduced-motion`, the grid has no transitions.
