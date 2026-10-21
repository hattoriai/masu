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

## Very tall grids

A browser draws no element taller than a limit: 17,895,697 pixels in
Firefox, 33,554,428 in Chromium and Safari. The scroll box of a grid
taller than 10,000,000 pixels (about 280,000 rows of 36 pixels) is
10,000,000 pixels tall, and its scrollbar moves through the rows in
proportion: a drag of the scrollbar, and a scroll by touch, move
faster than the rows under them. A wheel, a trackpad and the keys move
by their own pixels and rows.

## Groups in a database

An Ecto source keeps the groups that show (their values, counts and
totals) in the LiveView: grouping by a column of a hundred thousand
values holds a hundred thousand groups. SQLite sums decimals as floating
point numbers; PostgreSQL and MySQL sum them exactly. A database orders
`NULL` groups by its own rule, a list puts them last. Following a person
(`Masu.Presence`) does not find their row in a grouped Ecto grid, and a
detail does not show there.

## A tree in a database

An Ecto tree keeps the ids of the rows that show, and reads a block's
rows with `WHERE id IN (...)`. A filter keeps its matches and their
ancestors the same way, so a filter that keeps hundreds of thousands of
rows of a tree runs into the database's limit of query parameters
(65,535 in PostgreSQL). A tree deeper than a hundred levels shows its
deeper rows as roots while a filter applies.

## Details

A detail is as tall as its content, and the rows are one height: a
detail of a grid in a detail is measured as it changes. Fifty details
are open at most.

## A deep OFFSET

An Ecto source reads the block after a block it read by key (see
[Export, selection and large tables](export.md)), but a jump into the
middle of a table of millions of rows (the scrollbar dragged) is an
`OFFSET`, which the database counts row by row. A grouped Ecto grid
reads an open group's rows by `OFFSET`. Paging by key is tested on
SQLite; the order of `NULL`s it assumes for PostgreSQL is PostgreSQL's
default. With an adapter other than PostgreSQL, MySQL, SQLite and SQL
Server, a sort other than the primary key's is read by `OFFSET`.

## Export

An export downloads from the app's export route (`Masu.Router`), not
over the LiveView's socket, as its rows are read: a block of 500 rows at
a time, from an Ecto source by key. Its link is good once, for five
minutes, and from the LiveView that made it while it runs. On several
nodes, the download must reach a node connected to the LiveView's
(distributed Erlang). An XLSX file is zipped as it is written, with no
ZIP64: its sheet stays under 4 GB, and it has Excel's 1,048,576 rows at
most (a CSV export has every row). An XLSX file's dates before 1900 are
numbers Excel does not show as dates.

## Empty values in a database

A list puts empty values (`nil`) last in both directions. A database puts
them where it does: PostgreSQL last when ascending and first when
descending, MySQL and SQLite first when ascending.

## A large list

A list (`rows={@rows}`) is for up to about 10,000 rows. It sorts and
searches in the LiveView's process, and the LiveView holds the rows, so
each person who has the grid open holds a copy: about 1 KB a row. A
search makes a text of each row the first time, and searches after it
are fast; a sort sorts every row again.

| Rows | Sort by a column | First search | Each search after | Memory of a LiveView |
| --- | --- | --- | --- | --- |
| 10,000 | 23 ms | 36 ms | 2.6 ms | 9 MB |
| 100,000 | 396 ms | 355 ms | 27 ms | 86 MB |
| 1,000,000 | 5.2 s | 5.0 s | 274 ms | 863 MB |

Past 10,000 rows, give the grid an Ecto source: the database sorts,
searches and counts, and the LiveView holds only the rows on the screen.
Masu has no list source for a larger list in memory yet, as rows off the
LiveView's heap and shared between people. If you need one, [open an
issue](https://github.com/hattoriai/masu/issues) or a pull request.

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

## Editing a large list

A grid of a list saves an edit by finding its row by its id and applying
the query again, as for a live change: a fifth of a second for a hundred
thousand rows. An Ecto source asks the database instead.

## A paste or a fill of many cells

A paste, a fill or an emptied range saves at most five thousand cells at
once, and only of rows that the browser can ask for.

## What the browser may send

Any person can craft the events the browser sends, so Masu checks the
texts and lists below where they come in, and no source or store needs
to check them again. A text or a list
past a bound is refused, never cut short. Texts are counted in bytes, not
characters: "é" is two bytes.

| What | At most |
| --- | --- |
| The search of the grid, the search of a column's values, the text of a filter value (each value of a list filter too) | 1,000 bytes |
| Filters in a query | 100 |
| Sorts in a query | 100 |
| Groups in a query | 100 |
| Values of a list filter (`:in`, `:all_of`, `:none_of`) | 10,000 |
| The name of a saved view | 255 bytes |

Filters, sorts and groups are counted as they are sent, before repeated
sorts and groups are removed.

A NUL character (`\u0000`) is refused in every text of the table, and in
a text that a person edits or adds to a cell. PostgreSQL cannot store
one. A NUL is never meaningful in a search, so the person gets an error.

What the grid does past a bound, or with a NUL, depends on where the text
came from:

- **An event of the grid** (a query, a name for a view) is answered with
  an error: "the search is longer than 1,000 bytes". The grid keeps the
  query it had. A filter that does not check is an error in the grid's
  own `filters` too.
- **The search of a column's values** (the filter menu) gets no values,
  as the menu has no place for an error.
- **A link or a view** (the URL, a saved view, the last view) is left out
  of the view where it is past a bound, and the grid says so (see
  [Views that no longer apply](views.md#views-that-no-longer-apply)). The
  whole part goes, never a cut of it: the search, or all the filters
  when there are too many.
- **An edit, a paste, a fill or a new row** refuses the cell with the
  NUL, and saves the others.

The keys of columns are matched against the grid's own columns, so a
layout never holds text from the browser.

The ids of rows, and of a selection, are not checked here: an id the
source cannot read fails as any malformed event does.

## A primary key of several fields

An Ecto source finds a row to edit by a primary key of one field.
