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

## Announcements

A live region says how many rows a sort, a filter or a search gives
("9,412 rows"), how many rows were selected or copied, and why a query
was refused. Its words are in `messages`.

## Motion

Under `prefers-reduced-motion`, the grid has no transitions.
