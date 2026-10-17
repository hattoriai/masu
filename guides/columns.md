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

## Width and alignment

`width` is the first width of the column, in pixels; the person may
resize it, down to `min_width` (48 unless given). The default width
follows the type: 200 for text, 120 for integers and numbers, 140 for
decimals and dates.

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
