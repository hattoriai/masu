# Filters

The filters of a grid show above it, in the filter bar: a chip for each,
which says its column, its operator and its value (**Plan** is one of
**team, free**). A click on a chip opens its filter, to change it; its ×
takes it away; Clear all takes them all. **Add filter** lists the columns
that filter, and opens the filter of the one picked.

Each header has a menu too, its **⋯** (on hover, or Alt+↓ on a header from
the keyboard): its sorts (ascending, descending, and Clear sort when it
sorts by it), the app's items for it, Group by, and its filter. A click on
the header's label sorts, as before.

## Three headers

| | The filter bar (the default) | `header_filters={false}` | `filter_bar={false}` |
| --- | --- | --- | --- |
| Above the grid | the chips, and Add filter | the chips, and Add filter | the chips, while there are filters |
| A header's menu | **⋯**: its sorts, items, Group by and filter | **⋯**: its sorts, items and Group by | the funnel: its filter, items and Group by |

```heex
<%!-- The filters in the bar alone: a header's menu sorts --%>
<.data_grid id="orders" source={Order} repo={Repo} header_filters={false}>

<%!-- The leaner header: no bar, a funnel on each header that filters --%>
<.data_grid id="orders" source={Order} repo={Repo} filter_bar={false}>
```

The filter bar takes a line above the grid, whether or not a filter is
set, so that a filter is always one click away and every filter shows
where it can be read. `filter_bar={false}` gives that line back, for a
grid in a small place: its filters are on its headers, and its chips show
only while it has some. The two can go together: with both `false`, a
grid's filters come from its LiveView (`filters`) and a cell's menu alone.

A header's button is at its end, the same place in every column, and at
its start in a header that aligns to the end (a number's), whose label
stays over its column's values.

## The filters of each type

| Type | The menu offers |
| --- | --- |
| text | contains, is, is not, starts with, ends with, does not contain, is empty, is not empty |
| enum | its values, with how many rows have each, to tick; is empty, is not empty |
| integer, number, decimal | is, is not, greater than, at least, less than, at most, between, is empty, is not empty |
| date, datetime, time | is, after, on or after, before, on or before, between, is empty, is not empty |
| boolean | yes or no, is empty |
| many values | has any of, has all of, has none of (its values, to tick), has none, has some |

A column has one filter in the menu; the filters of several columns all
apply. The grid's search applies with them.

A source of your own may run fewer: the menu then offers those (see
[The filters a source runs](sources.md#the-filters-a-source-runs)).

## Many values

A column of many values (a path through several related rows,
`field={[:tags, :name]}`, see [Columns](columns.md#a-field-of-a-related-row))
filters by its values: "has any of" (`:in`), "has all of" (`:all_of`)
and "has none of" (`:none_of`) the values ticked, "has none"
(`:is_nil`, no value at all) and "has some" (`:not_nil`). Its menu lists
each value with how many rows have it. The menu of its cell filters by
none or some.

An Ecto source runs each as a subquery of the related rows, so a row
is never repeated, and the count is of rows, not of their values.

## The values of an enum

An enum's menu lists its values among the rows of the person's other
filters and search, the most frequent first, with how many rows have
each: what a person may add to what they see. A column with more than
eight values has a search box over them. The source counts them: a list
in the LiveView, an Ecto source with one `GROUP BY` of its query. A
column of your own HEEx is listed by its values, not its HTML.

A source of your own offers values with the optional `values/5` callback
of `Masu.Source`; without it, an enum's menu has no values to tick.

## Filters of the LiveView

The `filters` attribute gives the grid's first filters, which show as
chips as the person's do, whatever the header:

```heex
<.data_grid id="orders" source={Order} repo={Repo} filters={[{:status, :in, ["paid", "late"]}]}>
```

See `Masu.Filter` for the operators, and how a value is read for its
column's type.

## Testing

```elixir
assert values(view, "orders", "status") == [{"paid", 3}, {"late", 1}]

view |> filter("orders", [{"status", :in, ["paid"]}])
assert total(view, "orders") == 3

view |> filter("orders", [{"customer.name", :eq, "Ana"}, {"tags", :all_of, ["gift", "urgent"]}])
```

## Words

The words of the menu (the operators, Apply, Clear) are in the grid's
`messages`: `op_contains`, `op_gt_time` ("after"), `op_in_many` ("has
any of"), `op_all_of`, `op_none_of`, `op_is_nil_many` ("has none"),
`apply`, `clear`, `clear_all`, the filter bar's `add_filter` and
`no_columns`, a header menu's `sort_asc`, `sort_desc` and `sort_clear`,
and the others of the bundle, which the attribute replaces.
