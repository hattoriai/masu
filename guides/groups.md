# Groups and totals

Rows grouped by the values of their columns, each group a row of its own
with how many rows it has and their totals, and a row of totals at the
bottom of the grid.

```heex
<.data_grid id="orders" source={Order} repo={Repo} group_by={[:status, :customer]}>
  <:col field={:number} />
  <:col field={:customer} />
  <:col field={:status} type={:enum} />
  <:col field={:total} type={:decimal} aggregate={:sum} />
  <:col field={:placed_on} type={:date} aggregate={:max} />
</.data_grid>
```

## Totals

`aggregate` on a `:col` totals it:

| Aggregate | Is |
| --- | --- |
| `:sum` | the sum of the values; decimals add up exactly in a list |
| `:avg` | their average; an average of decimals has six places at most |
| `:min`, `:max` | the smallest and the largest, of any type that sorts (dates too) |
| `:count` | how many rows have a value |
| `:count_distinct` | how many values there are |
| a function | for a list: a function of the rows, `&length/1` say |

A grid with a column that totals has a row of totals at the bottom, of
every row of the query (with the person's filters and search), grouped
or not. It sticks to the bottom of the grid as the rows scroll.

## Groups

`group_by` names the columns the rows start grouped by, the first the
outermost. A person groups by a column from its header menu ("Group by
Plan"), and stops from it, or from the column's chip above the grid
("Grouped by Plan ×"). The grouping is part of their view (`group` in
the URL's params and in saved views, see [Layout and views](views.md)).

Each group is a row, in the first column: its column, its value and how
many rows it has, with the totals of its rows in their columns. A group
opens on the groups of the next column, or on its rows, as a tree does:
the arrow, → and ← on the first column, `*` for every group beside it
(see [Trees and details](trees.md)). Groups start closed.

**Open from the start.** `expanded` starts groups open: `:all` every
group at every level, down to the rows, or the keys of the columns whose
groups open, the outer ones say.

```heex
<%!-- every group open, and every customer in it --%>
<.data_grid id="orders" rows={@orders} group_by={[:status, :customer]} expanded={:all}>

<%!-- the statuses open on their customers; the customers closed --%>
<.data_grid id="orders" rows={@orders} group_by={[:status, :customer]} expanded={[:status]}>
```

A group the person closes stays closed, with a new filter or view too.
A column they group by from the header menu opens by the same rule:
with `:all`, its groups start open. In the database, `:all` reads
every level of groups at the start, where closed groups read only the
first; the rows still come a block at a time (see below).

**Order.** Groups sort by their value. Sorting by the grouped column
turns their order; sorting by a column that totals sorts the groups by
their totals ("plans by revenue"). The rows of a group sort as the
grid's rows do.

**Filters.** A filter or a search applies to the rows: the groups count
and total what it keeps, and a group with no row left goes.

**Live rows** (`Masu.Live`) move between groups as they change, and the
counts and totals follow. A group's row does not edit.

## In the database

An Ecto source counts and totals in the database: one `GROUP BY` for
each level of groups that shows (with the person's filters and search),
and one query for the totals. The rows of an open group are read a
block at a time, as any rows are, with the group's values in the
`WHERE`. A million rows in forty groups are forty rows until one opens.

Only columns that name a field group and total in the database; an
aggregate function is for a list.

## Testing

`Masu.Test.group/3` groups as the header menu does, `Masu.Test.groups/3`
reads the groups' rows (their value, count, level and totals), and
`Masu.Test.totals/2` the row of totals. A group's id is its path,
`["masu-group", "status", "paid"]`: `Masu.Test.expand/3` opens it.
