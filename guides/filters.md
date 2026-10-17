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

A column has one filter in the menu; the filters of several columns all
apply. The grid's search applies with them.

A source of your own may run fewer: the menu then offers those (see
[The filters a source runs](sources.md#the-filters-a-source-runs)).

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
```

## Words

The words of the menu (the operators, Apply, Clear) are in the grid's
`messages`: `op_contains`, `op_gt_time` ("after"), `apply`, `clear`,
`clear_all` and the others of the bundle, which the attribute replaces.
