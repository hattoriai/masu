# Backlog

Known gaps in Masu, each to become an issue. The planned work is in the
issues:

- [#1](https://github.com/hattoriai/masu/issues/1) Column layout and saved views
- [#2](https://github.com/hattoriai/masu/issues/2) Tree rows and detail rows
- [#3](https://github.com/hattoriai/masu/issues/3) Grouping with totals, computed in the database
- [#4](https://github.com/hattoriai/masu/issues/4) Scale and output: export, paging by key, select every row of a query
- [#5](https://github.com/hattoriai/masu/issues/5) Finish editing: new rows, deleting rows, richer editors
- [#6](https://github.com/hattoriai/masu/issues/6) Sources without an exact count, and an optional pager
- [#7](https://github.com/hattoriai/masu/issues/7) Change history: who changed a cell, when, and restoring a value
- [#8](https://github.com/hattoriai/masu/issues/8) Following a person shows their view, not only their cell
- [#14](https://github.com/hattoriai/masu/issues/14) Custom actions on selected rows and on each row
- [#15](https://github.com/hattoriai/masu/issues/15) Koyomi pickers for date and time cells and filters
- [#16](https://github.com/hattoriai/masu/issues/16) Kotoba for rich text cells, kept minimal
- [#17](https://github.com/hattoriai/masu/issues/17) Editors of your own: an app's input for a column's cells

The rest, below, is not planned yet.

## Collaboration: comments on cells

A thread of comments on a cell, by its row id and column key: a mark in
the cell's corner, the thread on hover or Enter, and the comments to the
others as they are written, with a store of your own (a behaviour, and
an Ecto one).

## Live rows: keep the row the person reads

A live change keeps the scroll, so a row inserted above the screen moves
the rows below it down by one. Keep the first row on the screen in its
place instead (by its id), as a feed does.

## Filters: pickers and more values

The date filters use the browser's own date inputs; Koyomi's pickers
are #15. Offer the values of a text column, as an enum's
are, when it has few. Several filters on one column (a range and empty).

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
