# Known limits

What Masu does not do yet, or does with a cost to know.

## Browsers

The grid needs a browser with `ResizeObserver`, `Intl.NumberFormat` and
`Intl.DateTimeFormat`: every browser of the last few years. Decimals keep
every digit where the browser formats a decimal string exactly
(`Intl.NumberFormat` v3: Chrome 106, Firefox 116, Safari 15.4); an older
browser rounds a decimal of more than fifteen digits as it shows it. The
copy is exact in every browser.

## Rows of one height

Every row has the height of `row_height`. A cell does not wrap, and
clips what does not fit.

## A deep OFFSET

An Ecto source reads a block with `LIMIT` and `OFFSET`. Deep in a table
of millions of rows, the database reads every row before the offset, and
a block takes longer. Paging by key (after the last row's sort values)
is in the backlog.

## Empty values in a database

A list puts empty values (`nil`) last in both directions. A database puts
them where it does: PostgreSQL last when ascending and first when
descending, MySQL and SQLite first when ascending.

## Sorting a list

A list sorts in the LiveView's process: about a fifth of a second for a
hundred thousand rows by one column. A larger list belongs in a database.

## Datetime filters

The menu takes a date and a time in the browser's time zone, and gives
the server the instant. A list compares it with a `NaiveDateTime` as if
that were UTC. An Ecto source compares it with the column's type: a
`:naive_datetime` column takes it in UTC.

## One filter a column in the menu

The menu edits one filter a column. The `filters` attribute and
`Masu.Test` may give a column several, which all apply; the menu then
shows the first, and replaces them all.

## Pages without LiveView

The grid is a LiveComponent: it needs a LiveView.

## Copy of a large range

A copy takes at most ten thousand rows. When the browser lacks some of
them, it asks the server, and writes the clipboard when they come;
Firefox and Safari may refuse to write it that late, and the grid then
says the rows could not be copied.

## Live changes to a large list

A grid of a list takes a batch of changes by finding each row by its id
and applying the query again: a fifth of a second for a hundred thousand
rows. For a list that large that changes often, use an Ecto source,
which asks the database instead.
