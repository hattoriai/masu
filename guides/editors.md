# Editors of your own

A cell edits with the editor of its column's type: a text box for text
and numbers, the browser's date and time inputs, a toggle for booleans, a
list for an enum. A column may bring its own instead, with `editor`:

* **a form of HEEx**, a function component that the server renders in a
  popover under the cell. Whatever its form posts is the new value: a
  Koyomi picker, a Kotoba editor, a search of your users, any HEEx and
  any LiveView hook. No JavaScript of your own;
* **an editor of the browser's**, a JavaScript function you give to
  `configure`, drawn over the cell at once: a slider, a color, a tag
  input.

Either way the grid keeps the rest of an edit as it does for its own
editors: the changeset (or `on_update`, see [Editing](editing.md)), the
errors on the cell, undo and redo, the cells changed meanwhile (a
compare-and-swap), "Ada is editing" for the others, and paste, fill down
and Delete, which go through the column's type, not the editor.

## A form of HEEx

```heex
<.data_grid id="bookings" source={Booking} repo={Repo} changeset={&Booking.changeset/2}>
  <:col field={:guest} />
  <:col field={:notes} editor={&notes_editor/1} />
</.data_grid>
```

```elixir
defp notes_editor(assigns) do
  ~H"""
  <textarea name={@field.name} rows="4" aria-labelledby={@label_id}>{@field.value}</textarea>
  """
end
```

The component gets:

| Assign | |
| --- | --- |
| `field` | a `Phoenix.HTML.FormField` of the cell's value, named `cell[value]`: what the form posts under it is the new value |
| `form` | its form |
| `value`, `row`, `id` | the cell's value and its row, as the source reads them now, and the row's id |
| `column` | the `Masu.Column` |
| `label`, `label_id` | the column's label, and the id of an element that has it, for the input's `aria-labelledby` |
| `scope` | the grid's `scope` |

What the form posts goes to the changeset as the field's params, as a
form's do: text for `cell[value]`, a map for `cell[value][from]` and
`cell[value][to]`, a list for `cell[value][]`. Your Ecto type casts it.

### Kotoba: rich text in a cell

[Kotoba](https://hex.pm/packages/kotoba)'s editor posts its document in a
hidden input of its field, and `Kotoba.Content` casts it: a cell of rich
text is one component.

```heex
<:col field={:notes} editor={&notes_editor/1} sortable={false} filterable={false} width={320} />
```

```elixir
defp notes_editor(assigns) do
  ~H"""
  <.kotoba field={@field} id={"notes-#{@id}"} label_id={@label_id} features={~w(bold italic links lists)} />
  """
end
```

`features` keeps the editor to what fits a cell. The cell shows the
document's text, given by `Masu.Wire` (below); a `:col` with content
shows it as you like, `<.kotoba_content>` too. The `Kotoba` hook is in
your LiveSocket as for any Kotoba editor.

### Koyomi: pickers for dates and ranges

[Koyomi](https://hex.pm/packages/koyomi)'s pickers post what the
browser's inputs post (`2027-03-15`, or `from` and `to` for a range), and
its Ecto types cast it:

```heex
<:col field={:check_in} type={:date} editor={&date_editor/1} />
<:col field={:stay} editor={&stay_editor/1} sortable={false} filterable={false} width={260} />
```

```elixir
defp date_editor(assigns) do
  ~H"""
  <.date_picker field={@field} label_id={@label_id} />
  """
end

defp stay_editor(assigns) do
  ~H"""
  <.date_range_picker field={@field} label_id={@label_id} months={2} />
  """
end
```

The rules, locales and time zones of a picker are Koyomi's, as in any
form, and `Koyomi.Changeset` checks the same rules in your changeset.
Escape closes the picker's calendar first, then the editor.

### A search of the server

The component renders in the LiveView's process: a `Phoenix.LiveComponent`
in it searches as the person types, with its own events, and puts the
pick in an input of the field.

```elixir
defp assignee_editor(assigns) do
  ~H"""
  <.live_component module={MyAppWeb.UserSearch} id={"assignee-#{@id}"} field={@field} scope={@scope} />
  """
end
```

### Keys and focus

| | |
| --- | --- |
| Enter, F2, a double click | opens the editor; the first control of the popover has the focus |
| Ctrl+Enter (⌘↩), a submit of the form | saves (Enter in a single-line input submits a form; Enter in a text area, or a rich text editor, is the editor's) |
| A click away | saves |
| Escape | lets the edit go, once the editor's own Escape (a picker's calendar) is done |
| Tab | moves between the controls of the popover |

A form that posts what it posted when it opened saves nothing. The
popover is a dialog labelled by the column's label; the focus goes back to
the grid when it closes.

## An editor of the browser's

Give your editors to `configure`, in your app's JavaScript, by name:

```js
import { Masu, configure } from "masu"

configure({
  editors: {
    score: ({ element, value, options, label }) => {
      const input = Object.assign(document.createElement("input"), {
        type: "range", min: options.min ?? 0, max: options.max ?? 100, value: value ?? 0,
      })
      input.setAttribute("aria-label", label)
      // The arrows are the slider's.
      input.addEventListener("keydown", (event) => {
        if (event.key.startsWith("Arrow")) event.stopPropagation()
      })
      element.append(input)
      return { value: () => Number(input.value), focus: () => input.focus() }
    },
  },
})
```

```heex
<:col field={:score} type={:integer} editor={{"score", %{max: 100}}} />
<:col field={:color} editor="color" />
```

The function gets a context, and gives the editor:

| The context | |
| --- | --- |
| `element` | a box over the cell, as wide as the column and as tall as the row, to draw in |
| `value`, `text` | the cell's value as the browser has it, and the character typed that opened the editor |
| `id`, `row` | the row's id, and its values by column key |
| `column`, `options`, `label`, `locale` | the column, the options of its `editor`, its label, the grid's locale |
| `commit(value, move)` | saves a value; `move` is `"down"`, `"up"`, `"right"` or `"left"` |
| `cancel()` | lets the edit go |

| The editor | |
| --- | --- |
| `value()` | the value now, which the grid saves on Enter, Tab and a click away |
| `focus()` | takes the focus (the first control of `element` does unless given) |
| `contains(node)` | whether a node outside `element` is the editor's (a list it put in `document.body`) |
| `destroy()` | called when the editor closes |

The keys an editor handles, it prevents (`event.preventDefault()`) or
stops: the grid acts on the others: Enter saves and moves down
(Shift+Enter, up), Tab right (Shift+Tab, left), Escape lets the edit go.
The grid checks the value by the column's type before it saves it, as it
does for its own editors, and the changeset has the last word.

An editor that is not given to `configure` leaves the column with the
editor of its type, and says so in the browser's console.

## Values of your own types: `Masu.Wire`

A cell shows its value as the browser gets it: numbers, decimals, dates
and times, booleans, text, and structs that implement `String.Chars`.
For another type, implement `Masu.Wire`: what the cell shows, what a copy
and an export take.

```elixir
defimpl Masu.Wire, for: Kotoba.Content do
  def to_wire(content), do: content.text
end

# Koyomi.DateRange's values are Date.Range.
defimpl Masu.Wire, for: Date.Range do
  def to_wire(range), do: "#{range.first} → #{range.last}"
end
```

The editor gets the value as the row has it, not this. A column of such
values sorts and filters only as far as its source can: give it
`sortable={false}` and `filterable={false}` unless its database column
does.

## New rows

A new row, until it saves, has no id for the server to find: its cells
edit with the editors of their types.

## Testing

```elixir
view = open_editor(view, "bookings", 1, :notes)
assert has_element?(view, ~s(#bookings-cell-editor textarea[name="cell[value]"]))

assert :ok = edit(view, "bookings", [{1, :notes, "Late check-in"}])
assert :ok = edit(view, "bookings", [{1, :stay, %{"from" => "2027-03-15", "to" => "2027-03-20"}}])
```

`open_editor/4` renders the form, as the browser's Enter does;
`edit/4` saves what it would post, as the browser does. An editor of the
browser's is tested in the browser.
