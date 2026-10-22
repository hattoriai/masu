# In a document

A grid is a view of your app's rows; a document is text people write. A
grid in a document (a [Kotoba](https://hex.pm/packages/kotoba) embed) is
the rows themselves, live, among the text: people sort, filter and edit
them where they read about them, and the document keeps only which grid
and which view.

A table of the document (Kotoba's own) is the other thing: a few rows
that exist only because of the document, with no source. If the rows
would be there without the document, it is a grid.

## The grid in a page

Three attributes make a grid a part of a page that scrolls:

```heex
<.data_grid {MyApp.Grids.tasks(@scope)} height="auto" max_height="24rem" wheel={:page} view={@view_params} />
```

* `height="auto"`: the grid is as tall as its rows, up to `max_height`
  (32rem unless given); past it, the rows scroll. Five open tasks take
  five rows of the page, not a box of 32rem.
* `wheel={:page}`: the wheel scrolls the page past the grid, until the
  person is in it (a click on it, Tab); then the wheel is the grid's. A
  grid alone on a page keeps the wheel (`:grid`, the default).
* `view`: the view the grid opens with, as a view's params (see
  [Layout and views](views.md)): its order, filters, search and columns.
  A saved view's `params` (`Masu.Views`) are such a view.

## A grid in a Kotoba document

Kotoba keeps an embed's `kind` and `ref`, and your LiveView renders it
([Embeds](https://hexdocs.pm/kotoba/embeds.html)). For a grid, a good ref
is a saved view: "Unpaid invoices over €1,000" is what a document talks
about, more than the invoices table.

```heex
<.kotoba field={@form[:body]} id="doc" embeds />

<.kotoba_embeds for="doc" label="Grid" icon="grid" readonly={@reading}>
  <:embed :let={embed}>
    <% view = MyApp.GridViews.get(embed.ref) %>
    <.data_grid
      :if={view}
      {MyApp.Grids.for_view(view, @scope)}
      id={"grid-" <> embed.id}
      view={view.params}
      height={if embed.full, do: "100%", else: "auto"}
      wheel={if embed.full, do: :grid, else: :page}
      changeset={if !embed.readonly, do: &MyApp.Tasks.Task.changeset/2}
    />
  </:embed>
  <:picker>
    <.kotoba_embed_option :for={v <- @views} phx-click="insert_grid" phx-value-id={v.id} title={v.name} />
  </:picker>
</.kotoba_embeds>
```

```css
/* A grid takes the height of its rows; a canvas keeps the embed's. */
.kotoba-embed[data-kind="grid"] .kotoba-embed-slot { height: auto; }
```

* Give the grid an id of the embed's (`"grid-" <> embed.id`): the same
  view can be in a document twice.
* Check that the person may see the view the ref names, as for any of
  your pages: a document's refs are the person's input.
* Full screen (`embed.full`) is the whole screen: the grid takes it all
  (`height="100%"`) and the wheel.
* A page that reads the document (`embed.readonly`) shows the grid with
  no changeset: people sort and filter it, and change nothing.
* Kotoba keeps the keys of an embed in it: the arrows, Enter and ⌘C are
  the grid's.

## Markdown and HTML

A document exported to Markdown has its grid as a table of its rows, as
they are: a snapshot (`Masu.Snapshot`), which Markdown viewers draw, and
which Kotoba reads back as the grid (it keeps the embed's kind and ref
around it).

```elixir
def render(%{kind: "grid", ref: ref}, format) when format in [:markdown, :html] do
  view = MyApp.GridViews.get(ref)
  sheet = Masu.Sheet.new(MyApp.Grids.for_view(view, scope))

  case format do
    :markdown -> Masu.Snapshot.markdown(sheet, view: view.params, rows: 20)
    :html -> Masu.Snapshot.html(sheet, view: view.params, rows: 20)
  end
end
```

```markdown
<!-- kotoba:embed {"kind":"grid","ref":"12","title":"Open tasks"} -->

| Task | Due | Done |
| :--- | :--- | :---: |
| Write the guide | 2026-11-02 | false |

_And 37 more rows._

<!-- /kotoba:embed -->
```

The snapshot is the view's rows (its order, filters, search, and the
columns that show), at most `rows` of them (20 unless given), and a line
of how many more. A cell is its value as text; a cell of your own HEEx is
its column's value. An HTML snapshot is a `table.masu-snapshot`, for a
page or an email of the document.

## Collaboration

A grid with `issho` is shared in its own room, whatever the document's:
its people are that room's, wherever they are. Give it its name in the
room, so that the embed and the grid's own page are one grid, and a
reader's `can`:

```heex
<.data_grid
  ...
  issho={[instance: MyApp.Issho, room: "tasks:#{@account.id}", grid: "tasks", can: (embed.readonly && :read) || :write]}
  user={@current_user}
/>
```

Someone reading the document and someone on the grid's page see each
other's cells and pointers. See
[Collaboration](collaboration.md#in-a-document-and-pointers).
