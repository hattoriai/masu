# Columns

Each `:col` slot of a grid is a column. Its attributes make a
`Masu.Column`.

```heex
<:col field={:total} type={:decimal} label="Total" width={140} />
```

## The value

`field` names the value of a row: a key of a map (an atom or a string)
or a field of a struct.

`value` computes it instead, from the whole row. A column with a `value`
needs a `key`, its name in `Masu.Test` and in filters:

```heex
<:col key="initials" value={&initials/1} label="Initials" />
```

A list sorts and filters such a column like any other. A database
cannot: with an Ecto source the column is shown, but does not sort,
filter or search (see [Sources](sources.md)).

### A field of a related row

`field` may be a path to a field of a related row: a list of the row's
associations (or keys of maps in it), and the field at the end.

```heex
<:col field={[:customer, :name]} label="Customer" />
<:col field={[:customer, :company, :country]} key="country" type={:enum} />
<:col field={[:tags, :name]} label="Tags" type={:enum} />
```

Its key is the path with dots (`"customer.name"`) unless given, the
name of the column in `Masu.Test`, filters and links. A row without the
related row (or with it not loaded) has no value there.

A path of one related row each step is one value, which sorts, filters,
searches and groups as any other: an Ecto source joins it (see
[Fields of related rows](sources.md#fields-of-related-rows)), and a list
follows it in each row. A path through several related rows (`has_many`,
`many_to_many`) is of many values: its cell shows them apart ("gift,
urgent"), and a cell of your own HEEx draws them as you like (chips for
tags). It filters by "has any of", "has all of", "has none of", "has
none" and "has some", and does not sort or group (see
[Filters](filters.md)).

The source says whether a path is of many values: an Ecto source from
the schema's associations, a list from its rows. A source of your own
says it with `many?/2`, or the column with `many={true}`.

The columns of related rows are read-only.

## The label

The header shows `label`, or the field in words (`inserted_at` is
"Inserted at"). Give `label` for the words of your app, in its language.

## Types

The type says how the browser formats a value in the grid's locale (the
`locale` attribute, or the browser's), how a filter reads the value it is
given, and where the cell aligns.

| Type | Shows | Aligns |
| --- | --- | --- |
| `:text` (the default) | the value as text | start |
| `:enum` | the value as text | start |
| `:integer` | `1,234` | end |
| `:number` | `1,234.5`, with up to ten decimal places | end |
| `:decimal` | `1,234.50`, with the digits the value has | end |
| `:date` | `17 Oct 2026` | start |
| `:datetime` | `17 Oct 2026, 14:30`, in the browser's time zone | start |
| `:time` | `14:30` | start |
| `:boolean` | a check mark for `true` | center |

A decimal goes to the browser as a string, so no digit is lost on the
way, and keeps the digits after the point that it has: `120.50` shows two.

A `DateTime` shows in the browser's time zone. A `NaiveDateTime` shows as
it is written, with no zone.

Numbers, dates and times use tabular figures, so the digits of a column
line up.

`raw` shows a column's values as the source gives them, not formatted
for the locale: `12345` and not `12,345`, `2026-10-18T08:00:00Z` and not
the date and time in the person's language. The column keeps its type,
for its alignment, its filters and its editor. A tool that shows data
as it is, as a SQL client does, wants it.

## Width and alignment

`width` is the first width of the column, in pixels; the person may
resize it, down to `min_width` (48 unless given). The default width
follows the type: 200 for text, 120 for integers and numbers, 140 for
decimals and dates. A column is at least its `min_width` wide.

### A column that takes the room

A grid wider than its columns leaves room after the last of them, while
a title or a description is cut short. `grow` gives that room to a
column, from its width up:

```heex
<.data_grid id="inbox" rows={@items}>
  <:col field={:title} min_width={280} grow />
  <:col field={:author} width={120} />
  <:col field={:updated} type={:datetime} width={170} />
</.data_grid>
```

The title is as wide as the grid leaves it, and follows the grid's width
as the window changes; in a grid narrower than the columns, it is its
width, and the grid scrolls sideways. Several columns that grow share
the room, each its share: `grow={2}` takes twice what `grow` takes. A
column pinned to the end stays at the grid's end.

A person who resizes a column that grows gives it their width: it is
that wide, and grows no more, in their view too (see [Layout and
views](views.md)). A column they resize beside it takes its room from
the column that grows, and gives it back.

`align` is `:start`, `:center` or `:end`. Numbers align to the end,
booleans to the center, everything else to the start.

## Totals

`aggregate={:sum}` (or `:avg`, `:min`, `:max`, `:count`,
`:count_distinct`) totals the column in a row at the bottom of the grid
and in the row of each group: see [Groups and totals](groups.md).

## Pinned and hidden

`pinned={:start}` or `pinned={:end}` keeps a column in view while the
others scroll sideways; `hidden` starts it hidden. A person moves, hides,
pins and resizes columns as they work: see [Layout and views](views.md).

## Sorting, filtering and searching

Every column sorts and filters unless it says `sortable={false}` or
`filterable={false}`. Text and enum columns are searchable, and others
are not, unless they say `searchable`.

## Cells of your own

A `:col` with content renders each of its cells, with the row as `:let`:

```heex
<:col :let={user} field={:name}>
  <.link navigate={~p"/users/#{user}"}>{user.name}</.link>
</:col>
```

The server renders the cells of the rows that the browser shows, as it
asks for them, and sends their HTML. The column's `field` and `type`
still say how it sorts and filters.

The content is a cell of a row of a fixed height: a link, a badge, an
icon, a line of text. A cell clips what does not fit.

A copy of a cell of your own gives its text, without the HTML.

## Columns not known in advance

A query tool knows its columns when its query runs: a result is a list
of column names, and rows as lists of values in their order, of no
types. A grid of it has no `:col` slots; `columns` names them:

```heex
<.data_grid id="result" rows={@result.rows} columns={@result.columns} row_id={:position} />
```

Each column is a key (a string), or a keyword list or map of a `:col`'s
attributes (`key`, `label`, `type`, `width`, `field`...):

```heex
<.data_grid id="result" rows={@rows} columns={["name", [key: "total", type: :decimal, label: "Total"]]} />
```

A column without a `field` reads the value at its place of a row that
is a list: the first column the first value. A column without a `type`
is `:auto`: the grid learns its type from the values of the first block
of rows (integers, decimals, dates, booleans...; values of several
types, or none, are text), so that numbers align to the end, dates show
in the locale, and each column has the filters of its type. A
`:col` takes `type={:auto}` and `field={2}` too.

A source of your own gives its columns with the optional
`c:Masu.Source.columns/1`, for a grid with neither `:col` slots nor
`columns` (see [Sources](sources.md)).

When the rows change for a result of other columns, the grid takes the
new columns, and learns their types again. The person's view keeps
what is of the columns there still (a sort, a filter, a width, a hidden
column) and names the rest, as a link to columns that are gone does;
their order is the new result's, unless the person moved columns. Rows
as lists have no ids: `row_id={:position}` says so, for a grid that
reads (see [Sources](sources.md#row-ids)). A column that reads a place
of a list does not edit.
