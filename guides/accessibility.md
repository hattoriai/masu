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

## The focus

The grid is one stop of the Tab key. The focus stays on the grid, and the
active cell is its `aria-activedescendant`: a screen reader follows the
cell as the arrows move it, while the rows come and go. See
[Keyboard and copy](keyboard.md) for the keys.

## The filter menu

The funnel of a header is a button named "Filter" and the column's label,
with `aria-haspopup="dialog"` and `aria-expanded`. The menu is a dialog
with the same name; the focus goes to its first field, and comes back to
the header when it closes. An enum's values are a group of checkboxes.
Each chip has a button that takes its filter away, named for it.

## Editing

The editor of a cell is an input named by its column's label, with the
focus while it is open; the focus comes back to the grid when it closes.
A cell the server refused has `aria-invalid="true"` and the error as its
title, and the live region says the error. In a column that edits, a cell
has `aria-readonly`: `"true"` when the row's state makes it read-only.

## Announcements

A live region says how many rows a sort, a filter or a search gives
("9,412 rows"), how many rows were selected or copied, and why a query
was refused. Its words are in `messages`.

## Motion

Under `prefers-reduced-motion`, the grid has no transitions.
