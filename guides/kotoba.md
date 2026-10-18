# Kotoba: rich text in cells

[Kotoba](https://hex.pm/packages/kotoba) is rich text for Phoenix: an
editor for LiveView forms and `Kotoba.Content`, an Ecto type that keeps a
document with its HTML and its text. A grid uses it with no dependency
of Masu's: its editor is an editor of your own (see
[Editors of your own](editors.md)), and its content a value of your own
type (`Masu.Wire`).

A cell is not a document. Keep the editor small (a few features, no
uploads), show the text in the cell, and leave sorting and filtering to
a plain column if the rows need them.

## Install Kotoba

As its README says: `{:kotoba, "~> 0.3"}`, `mix kotoba.install`, the
`Kotoba` hook in your LiveSocket next to `Masu`, and its style sheet.

```js
import { Masu } from "masu"
import { Kotoba } from "kotoba"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...colocatedHooks, Masu, Kotoba },
})
```

## The column

```elixir
schema "bookings" do
  field :guest, :string
  field :notes, Kotoba.Content
end

def changeset(booking, attrs) do
  booking
  |> cast(attrs, [:guest, :notes])
  |> Kotoba.Content.validate_features(:notes, ~w(bold italic links lists)a)
end
```

```heex
<.data_grid id="bookings" source={Booking} repo={Repo} changeset={&Booking.changeset/2}>
  <:col field={:guest} />
  <:col field={:notes} editor={&notes_editor/1} width={320} sortable={false} filterable={false} />
</.data_grid>
```

```elixir
import Kotoba.Components

defp notes_editor(assigns) do
  ~H"""
  <.kotoba field={@field} id={"notes-#{@id}"} label_id={@label_id} features={~w(bold italic links lists)} />
  """
end
```

Enter (or a double click) on a cell opens the editor in a popover under
it, with the cell's document. Ctrl+Enter (⌘↩) saves it, a click away
saves it, Escape lets it go; Enter is the editor's, for a new line or
list item. The editor posts its document in a hidden input of its field
(`cell[value]`), as it does in any form, and `Kotoba.Content` casts it in
your changeset. Undo, errors on the cell, and a cell changed by someone
else meanwhile are the grid's, as for any edit.

`id` must be unique on the page: give it the row's id, as above.
`features` keeps the editor to what fits a cell, and
`Kotoba.Content.validate_features/3` refuses in the changeset what the
editor does not have; no `uploads`, collaboration or prompts unless a
cell needs them.

## What the cell shows

A grid shows a value as the browser gets it. Tell it what a
`Kotoba.Content` is, once, in your app:

```elixir
defimpl Masu.Wire, for: Kotoba.Content do
  def to_wire(content), do: content.text
end
```

The cell shows the document's text, on one line; a copy and an export
take it too. To show the marks, render the cell yourself:

```heex
<:col :let={booking} field={:notes} editor={&notes_editor/1} sortable={false} filterable={false}>
  <.kotoba_content content={booking.notes} class="cell-notes" />
</:col>
```

```css
.cell-notes { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.cell-notes > * { display: inline; margin: 0; }
```

## Sorting, filtering, searching

A `Kotoba.Content` field is a document (JSON in the database): it does
not sort or filter as text. Keep `sortable={false}` and
`filterable={false}` on its column. To search notes, keep their text in
a column of its own (`Kotoba.Content` has it in `text`), and give the
grid that column, hidden if you like:

```heex
<:col field={:notes_text} label="Notes (text)" hidden />
```

## Paste and fill down

A paste and a fill down go through the column's type, not the editor:
they send your changeset the text of a cell, and `Kotoba.Content` casts a
document as JSON, not plain text. Plain text is refused, with the
changeset's error ("is invalid") on the cell. To take it, make a document
of text that is not JSON in your changeset, before `cast/3`:

```elixir
def changeset(booking, attrs) do
  booking
  |> cast(text_to_document(attrs), [:guest, :notes])
  |> Kotoba.Content.validate_features(:notes, ~w(bold italic links lists)a)
end

defp text_to_document(%{"notes" => text} = attrs) when is_binary(text) do
  case JSON.decode(text) do
    {:ok, _document} -> attrs
    {:error, _reason} -> Map.put(attrs, "notes", Kotoba.Content.from_markdown(text))
  end
end

defp text_to_document(attrs), do: attrs
```

## Two people

A cell someone else saved while the editor was open is refused ("Changed
by Ada meanwhile."), and the editor's document is not saved over theirs.
Kotoba's live collaboration is for documents, not cells: a cell is
edited by one person at a time, and the others see "Ada is editing".

## Testing

```elixir
view = open_editor(view, "bookings", 1, :notes)
assert has_element?(view, ~s(#bookings-cell-editor [phx-hook="Kotoba"]))

notes = Kotoba.Content.from_markdown("Late check-in, **call first**")
assert :ok = edit(view, "bookings", [{1, :notes, JSON.encode!(notes.doc)}])
```

`open_editor/4` renders the editor as Enter does; `edit/4` saves what it
would post, a document as JSON.
