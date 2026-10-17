# Backlog

Known gaps in Masu, each to become an issue. The first ones are the rest
of the first release: a grid that a team coming from AG Grid or TanStack
Table finds complete.

## Collaboration: more of a shared sheet

A click on an avatar goes to that person's cell (the server finds the
row's place in this person's order). Each person's selected range, as a
wash in their color. The name of who changed a cell meanwhile in the
refusal ("Changed by Ada meanwhile"). Comments on a cell.

## Live rows: keep the row the person reads

A live change keeps the scroll, so a row inserted above the screen moves
the rows below it down by one. Keep the first row on the screen in its
place instead (by its id), as a feed does.

## Filters: pickers and more values

The date filters use the browser's own date inputs; use Koyomi's pickers
when the app has Koyomi. Offer the values of a text column, as an enum's
are, when it has few. Several filters on one column (a range and empty).

## Editing: more editors, new rows

A select for an enum, of its values (as the filter menu has them);
Koyomi's pickers for dates and Kotoba for rich text, when the app has
them; an editor of your own in the `:col` slot. New rows (a row at the
end that adds one) and deleting rows. A decimal shown with the digits of
its column (`decimals={2}`), whatever the digits of its value.

## Grouping and totals

`group_by={:status}`: rows grouped under a row for each value, which opens
and closes, with totals (`aggregate={total: :sum}`). An Ecto source groups
and sums in the database (`GROUP BY`, with `ROLLUP` where the database
has it); a list in the LiveView. A row of totals pinned at the bottom.

## Rows in a tree, and rows that open

Tree rows: children with the columns of their parent, indented, opened
and closed (`role="treegrid"`, `aria-level`, `aria-expanded`), as a flat
list of the rows that are open, so that a tree of twenty thousand rows
scrolls as a list does. Rows that open on a detail of their own: any
component, or a grid of other columns.

## Pinned columns

Columns pinned to the start or the end, which stay while the others
scroll sideways.

## Hiding and moving columns

A menu of the columns, to hide and show them, and headers that move by
dragging.

## Saved views

The order, filters, search, widths, hidden columns and the order of the
columns, kept for each person (`Masu.Views`, with an Ecto store) and in
the URL, and named views to share.

## Select every row of a query

A selection of every row of the query, not of a list of ids, for an
action on a million rows (`Masu.Live.selected/2` gives the query).

## Export

CSV and XLSX of the whole query, streamed from the source, not only of
the rows the browser has.

## Paging by key

An Ecto source that reads a block after the sort values of the last row
of the block before (`WHERE (a, b, id) > (...)`) instead of an `OFFSET`,
so that the last block of a table of millions of rows is as fast as the
first.

## Column stats

A column's distribution in its header menu: a histogram for numbers and
dates, the top values for text, the empty values in percent; as Lotus
shows them.

## Rows of different heights

A row as tall as its content, measured as it is drawn.

## Pages without LiveView

`mountMasu()` for a grid in a controller's template, of the rows that the
page has, as Koyomi and Jumon have.

## Sizes of a touch screen

44px rows and handles on a touch screen, and a layout of cards on a
narrow one.

## Messages in other languages

`Masu.Messages`, with the words of the grid in the languages of Koyomi
and Jumon.
