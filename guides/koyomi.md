# Koyomi: pickers for dates, times and ranges

[Koyomi](https://hex.pm/packages/koyomi) is dates for Phoenix: pickers for
LiveView forms, `Koyomi.Rules` for the days a picker allows (the same in
your changeset), and Ecto types for ranges. A grid uses it with no
dependency of Masu's:

* in a cell, a picker is an editor of your own (see
  [Editors of your own](editors.md));
* above the grid, a picker in a form of your LiveView filters it,
  through the grid's URL.

## Install Koyomi

As its README says: `{:koyomi, "~> 0.2"}`, `mix koyomi.install`, the
`Koyomi` hook in your LiveSocket next to `Masu`, and its style sheet.

```js
import { Masu } from "masu"
import { Koyomi } from "koyomi"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...colocatedHooks, Masu, Koyomi },
})
```

## Pickers in cells

A column of dates, times or datetimes keeps its type (it sorts, filters
and formats as one); its editor is a picker of the same value:

```heex
<.data_grid id="bookings" source={Booking} repo={Repo} changeset={&Booking.changeset/2}>
  <:col field={:guest} />
  <:col field={:check_in} type={:date} editor={&check_in_editor/1} />
  <:col field={:arrives_at} type={:time} editor={&arrival_editor/1} />
</.data_grid>
```

```elixir
import Koyomi.Components

@check_in_rules Koyomi.Rules.new(min: :today, disabled_weekdays: [7])

defp check_in_editor(assigns) do
  assigns = assign(assigns, :rules, @check_in_rules)

  ~H"""
  <.date_picker field={@field} label_id={@label_id} rules={@rules} />
  """
end

defp arrival_editor(assigns) do
  ~H"""
  <.time_picker field={@field} label_id={@label_id} />
  """
end

def changeset(booking, attrs) do
  booking
  |> cast(attrs, [:guest, :check_in, :arrives_at])
  |> Koyomi.Changeset.validate_date(:check_in, @check_in_rules)
end
```

Enter (or a double click) on a cell opens a popover under it with the
picker, on the cell's value: its segments to type in or change with the
arrow keys, words ("next friday"), and its calendar. The picker posts the
form of the browser's own inputs (`2027-03-15`), which your changeset
casts as it casts a form's. Escape closes the picker's calendar first,
then the editor; Ctrl+Enter (⌘↩), Enter in the field, or a click away
saves.

The rules disable in the calendar what your changeset refuses, so a day
the picker lets the person choose saves, and one it does not is refused
with the changeset's error on the cell.

A `:datetime` column takes a `datetime_picker`, with the `time_zone` of
your users: it posts the wall clock time with the zone's offset, which
`:utc_datetime` casts.

## A range in a cell

`Koyomi.DateRange` keeps a range of days in one field: a PostgreSQL
`daterange`, or, with `storage: :map` or `:string`, a map or a text for
SQLite and MySQL. Its values are `Date.Range`s.

```elixir
schema "bookings" do
  field :stay, Koyomi.DateRange
end
```

```heex
<:col field={:stay} editor={&stay_editor/1} width={260} sortable={false} filterable={false} />
```

```elixir
defp stay_editor(assigns) do
  ~H"""
  <.date_range_picker field={@field} label_id={@label_id} months={2} />
  """
end
```

The picker posts `cell[value][from]` and `cell[value][to]`, and
`Koyomi.DateRange` casts the map; `Koyomi.Changeset.validate_range/3`
checks its rules (the shortest and longest stay).

A grid shows a value as the browser gets it. Tell it how a range of days
shows, once, in your app:

```elixir
defimpl Masu.Wire, for: Date.Range do
  def to_wire(range), do: "#{range.first} → #{range.last}"
end
```

A range sorts and filters only as far as its database column does; keep
`sortable={false}` and `filterable={false}`, or give the grid its first
day in a column of its own.

## A picker above the grid: filters

The grid's own filter menu filters a date column with the browser's date
inputs. For Koyomi's calendar, presets and words, put a picker above the
grid, in a form of your LiveView, and give the grid the filter through
its URL (`url`, with the `Masu.Live` hook):

```heex
<form id="placed" phx-change="placed">
  <label id="placed-label">Placed</label>
  <.date_range_picker name="placed" value={@placed} label_id="placed-label" relative months={2}
    presets={[:today, {:last, 7, :days}, {:last, 30, :days}, :this_month]} />
</form>

<.data_grid id="orders" source={Order} repo={Repo} url>
  <:col field={:number} />
  <:col field={:placed_on} type={:date} />
</.data_grid>
```

```elixir
def handle_params(params, _uri, socket), do: {:noreply, assign(socket, placed: params["placed"])}

def handle_event("placed", %{"placed" => placed}, socket) do
  params = %{"placed" => placed, "orders" => %{"filter" => placed_filter(placed)}}
  {:noreply, push_patch(socket, to: ~p"/orders?#{params}")}
end

# Days picked, or a preset's key ("last_7_days"): the days it covers today.
defp placed_filter(%{"from" => from, "to" => to}) when from != "" and to != "",
  do: %{"0" => %{"key" => "placed_on", "op" => "between", "value" => [from, to]}}

defp placed_filter(key) when is_binary(key) and key != "" do
  case Koyomi.Presets.to_range(key) do
    {:ok, range} -> placed_filter(%{"from" => to_string(range.first), "to" => to_string(range.last)})
    :error -> ""
  end
end

defp placed_filter(_cleared), do: ""
```

The grid reads its view from the URL's params under its id, and a
`between` filter of the column runs in the database, as the person's own
filters do: the chip shows it, and a link opens it. The picker keeps its
own value in the URL too (`placed=last_7_days`), so that it stays a
preset in a shared link. The grid's filters in the URL are the picker's:
merge the person's other filters (`params["orders"]["filter"]`) if they
should stay.

## Testing

```elixir
view = open_editor(view, "bookings", 1, :check_in)
assert has_element?(view, ~s(#bookings-cell-editor [phx-hook="Koyomi"]))

assert :ok = edit(view, "bookings", [{1, :check_in, "2027-03-15"}])
assert :ok = edit(view, "bookings", [{1, :stay, %{"from" => "2027-03-15", "to" => "2027-03-20"}}])
```

`open_editor/4` renders the picker as Enter does; `edit/4` saves what it
would post. `Koyomi.Test` picks values in a form of your LiveView, as for
the filter above.
