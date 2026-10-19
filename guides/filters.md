# Filters

Each column that filters has a menu: the funnel on its header (Alt+↓ on
a header, from the keyboard). The menu has the filters of the column's
type, and the filters that a person sets show as chips above the grid,
each with its button that takes it away.

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
chips as the person's do:

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
`apply`, `clear`, `clear_all` and the others of the bundle, which the
attribute replaces.
