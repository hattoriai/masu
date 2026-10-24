# Masu

![Masu — Tables for Phoenix](https://raw.githubusercontent.com/hattoriai/masu/main/media/banner.png)

Masu (枡, the squares of a grid) is tables for Phoenix. It gives your
app:

* a data grid for LiveView that draws only the rows on the screen, so a
  hundred rows and a hundred thousand scroll the same way;
* sources for its rows: a list the LiveView has, or an Ecto query or
  schema that sorts, filters, searches and counts in your database and
  reads only the rows the person sees;
* a `:col` slot for each column, with types that the browser formats in
  the locale (numbers, decimals to the last digit, dates and times) and
  cells of your own HEEx;
* editing, as in a spreadsheet, saved through your changeset: type on a
  cell, Enter and Tab, paste from a spreadsheet, fill down, undo; the
  changeset's errors on their cells;
* live rows: a grid that follows a PubSub topic shows the rows that
  change on it as they change, in the place of each person's order and
  filters, with a short highlight;
* collaboration, as in a shared spreadsheet: the avatars of the others
  who have the grid open, their cells in their colors, a cell someone
  types in locked for the others, and their saves flashing in their
  color;
* sorting by several columns, a search box, and filters in a bar above
  the grid: chips that say each filter and open it, Add filter, and a menu
  on each header with its sorts and filter, the values of an enum and
  their counts; or the leaner header, a funnel on each;
* columns that resize, and fit their content on a double click;
* menus of your own: items in each column's header menu, and a menu on
  each cell (a right click, or Shift+F10) with copy, filter by the
  value and sort, each item a function, an event to your LiveView, a JS
  command, or a panel your LiveView renders;
* the keyboard of a spreadsheet: the arrows, Page Up and Down, Home and
  End, a range selected with Shift, and ⌘C (Ctrl+C) that copies it as
  text a spreadsheet pastes;
* `Masu.Test`, to read, sort and filter a grid in
  `Phoenix.LiveViewTest` with no browser.

The grid is a prebuilt JavaScript bundle in the Hex package. Your app
does not run Node.js for it: you add the hook and one style sheet.

## What the grid does

| | |
| --- | --- |
| Rows | the rows on the screen and a few more are in the page; the others come from the server in blocks of a hundred as the person scrolls, once the scrolling pauses |
| Sources | `rows={@users}` for a list; `source={query} repo={Repo}` for Ecto, where a sort is an `ORDER BY`, a filter and the search a `WHERE`, and each block a `LIMIT`, read by key after the block before it; `Masu.Source` for your own; `load={:async}` reads a slow source in a task, with "Running…", Stop, a timeout and its errors; `on_query` for an app that runs its own queries, the grid a view of them |
| Editing | `changeset={&Order.changeset/2}`: a cell edits on a key typed, Enter, F2 or a double click; the edits of a row saved together with `Repo.update`, the errors on their cells, the old values back; paste of tab-separated text, fill down, Delete, undo and redo; read-only rows and cells by their state (`row_editable`, `editable={&...}`), checked on the server; a cell changed by someone else meanwhile refused (a compare-and-swap of each cell, in a transaction that locks the row); every write a `Masu.Write` for your own functions (`on_update`, `on_create`, `on_delete`, `on_restore`): row by row, a whole batch in one transaction (`Ecto.Multi`), the grid's own way and more, or later in a job (`Masu.Write.async/1`, `Masu.reply/2`), with the person's `scope` and what they did (a paste, a fill, an undo); a row found again through the grid's own query; new rows (`struct` with the changeset, or `on_create`) as drafts until they save, and a paste past the last row; deleting rows (`deletable`, `on_delete`) after a question, with undo; an enum's list of values, `decimals`, and values checked in the browser |
| Live rows | `live={{MyApp.PubSub, "orders"}}` and `Masu.Live.broadcast_upsert/3`: changes come into the person's query, a batch at a time, the scroll stays, the rows do not blink, the changed ones flash |
| Collaboration | on [Issho](https://hex.pm/packages/issho), as Kotoba's and Hakushi's: `issho={[instance: MyApp.Issho, document: "orders"]} user={...}`: avatars (a `:person` slot of your own), each person's cell by row id and column key whatever the others' order and filters, "Ada is typing" and a lock on that cell, flashes in the saver's color; a click on an avatar follows that person in their view (`share_view={false}` keeps it), each person's selected range in their color, "Changed by Ada meanwhile."; agents among the people, with tools that read and write a grid the grid's way (`Masu.Issho`, `Masu.Sheet`), that stop when a person pauses or stops them; Issho's comments on cells and ranges, their marks on the cells, their places in words (`Masu.Issho.label/2`); `configure({peerLabel})` and CSS for the rest |
| Layout and views | `pinned={:start}` and `hidden` columns; headers that move by dragging; a columns menu to show, hide, pin and move them; the person's view (order, filters, search, columns) in the URL (`url`) and kept per person, with named views to save and share (`views`, with an Ecto store and `mix masu.gen.views`) |
| Trees and details | `tree={:parent_id}`: rows in a tree, opened with →, ← and `*`, virtualized as a list of the open rows (a list or an Ecto source, children read as they open), siblings sorted among themselves, filters that keep the ancestors of a match; a `:detail` slot that opens a row on any HEEx under it, another grid too |
| Groups and totals | `group_by` and "Group by" in the header menu: groups with their counts and totals, opened as a tree, sorted by value or by a total; `aggregate={:sum}` and a row of totals at the bottom; counted and totalled by the database, a `GROUP BY` a level |
| Export and selection | an Export menu of CSV and XLSX of the whole query, streamed to the browser from a route of your router (`masu_exports`); `Masu.Live.export/1` for an app's own export; `selectable` rows, ranges, and every row of the query as an `Ecto.Query` (`Masu.Live.selected/1`); blocks of an Ecto source read by key, not `OFFSET`; counts deferred, on demand, or not known (`count`), and pages with a pager (`paging={:pages}`) |
| Editors of your own | `editor` on a column: a function component of a form field, rendered by the server in a popover under the cell, whose form posts the new value (a Kotoba editor, a Koyomi picker, a search of the server, with no dependency of Masu's); or an editor of the browser's, by name, given to `configure({editors})` (a slider, a color); the grid keeps undo, conflicts, errors, presence, paste; `Masu.Wire` for values of your own types |
| History | `history={MyApp.GridHistory}`: who changed each cell, when, from what to what, and what they did (typed, pasted, restored), in a popover from a cell's menu or Ctrl+Alt+H, for a cell or its row; Restore a value, or Undo all of someone's paste, as edits checked like any; `Masu.History.Ecto` in a table of any repo (PostgreSQL, MySQL, SQLite; the app's, recorded in the change's transaction, or one of its own), or a store of your own over your audit |
| Actions | `:action` on the rows selected, buttons of the bar above the grid, with every row of the query as one `Ecto.Query`; `:row_action` on each row, in a menu at its end (and on a right click, the context-menu key, Shift+F10), as functions, events to the LiveView, or links (`navigate`, `patch`); shown and disabled by the row, a question first (`confirm`), checked on the server; results said above the grid, and actions that go on in a job, with their progress (`Masu.progress/3`, `Masu.reply/2`) |
| Menus | `cell_menu`: a right click on a cell, or the context-menu key or Shift+F10, opens a menu of copy, copy with headers, filter by the value, exclude it, empty, and sort; `:header_action` and `:cell_action` add your items, each a function, an event to the LiveView, a JS command, or a panel of your HEEx under the header or the cell; for some columns (`columns`, `types`, `show`) or some people (`:if`), run only as the grid offers them |
| Columns | a field or a function of the row, a type, a width, an alignment; cells of your own HEEx, rendered on the server; columns not known in advance, as a query tool's results: rows as lists, `columns` with no `:col` slots, types learned from the values (`type={:auto}`) |
| Types | text, enums, integers, numbers, decimals (sent as text, so no digit is lost), dates, datetimes, times, booleans |
| Sorting | a click on a header; with Shift, by several columns, numbered in the headers; text without case, empty values last |
| Filters | the filter bar: the filters as chips above the grid, Add filter, and a menu on each header with its sorts and the filters of its type (or the filters in the bar alone, or a funnel on each header); contains, starts and ends with, greater and less than, after and before, between, empty; an enum's values ticked from a list with their counts (one `GROUP BY` in the database); checked against each column's type on the server |
| Search | a search box over the text columns, in the list or in the database |
| Keyboard | the arrows, Ctrl with them, Home, End, Page Up and Down, the header row, Enter on a header to sort, Shift to select, ⌘A, Escape |
| Copy | ⌘C copies the range as tab-separated values, the values themselves (numbers and dates as a spreadsheet reads them), and asks the server for rows the browser lacks |
| Locales | numbers, decimals, dates and times in the grid's locale, with the browser's `Intl` |
| Theming | CSS custom properties, the Sumi theme, dark mode, reduced motion |
| Accessibility | the WAI-ARIA grid with one tab stop and the active cell as `aria-activedescendant`, row and column counts and indexes, `aria-sort`, announcements |

## Performance

Measured with `mix bench` on an Apple M1 Pro, against two LiveView
pages of the same rows without a grid: one stream of every row, and the
infinite scroll of the LiveView docs (`phx-viewport-bottom`, a stream of
three pages of 50). In Chromium, with a list source:

| | Masu | A stream of every row | The infinite scroll |
| --- | --- | --- | --- |
| 100,000 rows: first rows on the screen | 0.4 s | 23 s | 0.4 s |
| DOM nodes, at 1,000 rows and at 1,000,000 | 374 and 374 | 1.1 million at 100,000 | 591 and 591 |
| Frames dropped in a fast scroll | none | every one | none |
| After a fast scroll | the rows there, once the scroll pauses | the rows there | no rows, and no more come |
| The scrollbar dragged to the middle | the rows there in 70 to 85 ms | the rows there | no scrollbar for the rows not read |

* An Ecto source on PostgreSQL reads a block of 100 rows in 0.25 ms,
  at the top of a table and in the middle of ten million rows: by key,
  not `OFFSET`. Sorted by a column with an index, 2 ms. A jump (the
  scrollbar dragged to rows the grid did not read) counts an `OFFSET`
  over the index: to the middle of ten million rows it takes 0.14 s, and
  0.2 s sorted by a column with an index (see [Known limits](guides/limits.md)). A
  `count(*)` of ten million rows takes seconds: `count={:deferred}`.
* A list source keeps its rows in the LiveView's process, about 1 KB a
  row for each person. It is for up to about 10,000 rows, which it sorts
  and searches in tens of milliseconds (23 ms and 36 ms). At 100,000
  rows a sort takes about 0.4 seconds and each person's LiveView holds
  about 100 MB. Past 10,000 rows, give the grid an Ecto source. If you
  need a larger list in memory, [open an issue](https://github.com/hattoriai/masu/issues) or a pull request.
* A grid of a million rows scrolls to its last row in Chromium, Firefox
  and Safari.

The numbers of the last run are in [bench/RESULTS.md](https://github.com/hattoriai/masu/blob/main/bench/RESULTS.md),
and how to run them in [bench/README.md](https://github.com/hattoriai/masu/blob/main/bench/README.md).

## Install

Masu needs Elixir 1.18 or later (it uses the built-in `JSON` module),
Phoenix 1.7.14 or 1.8, and Phoenix LiveView 1.1 or later. An Ecto
source needs Ecto 3.13 or later.

Add `masu` to the deps in `mix.exs`:

```elixir
def deps do
  [
    {:masu, "~> 0.7"}
  ]
end
```

Then run:

```sh
mix deps.get
mix masu.install
```

The installer adds the hook to `assets/js/app.js` and the style sheet to
`assets/css/app.css`, and prints what it changed. Give `--dry-run` to see
the changes first. It does not add what a file already has, so you can
run it again.

### The manual steps

To make the same changes by hand, import the hook in `assets/js/app.js`
and add it to the hooks of the `LiveSocket`:

```js
import { Masu } from "masu"

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Masu},
})
```

Import the style sheet in `assets/css/app.css` (and the Sumi theme, if you
want it: Sumi is the design system of Hattori AI, the makers of Masu,
Kotoba, Koyomi and Jumon). Put these lines below the other `@import`
lines of `app.css`:

```css
@import "../../deps/masu/priv/static/masu.css";
/* @import "../../deps/masu/priv/static/masu-sumi.css"; */
```

### `NODE_PATH=deps`

`import { Masu } from "masu"` resolves through the `NODE_PATH` of your
esbuild profile, which must have `deps/`. The Phoenix generators already
set it. If your profile has no `NODE_PATH`, add it in `config/config.exs`:

```elixir
env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
```

## Use

```heex
<.data_grid id="orders" source={Orders.for_shop(@shop)} repo={MyApp.Repo} label="Orders" searchable>
  <:col field={:number} width={120} />
  <:col field={:customer} />
  <:col :let={order} field={:status} type={:enum}>
    <.badge status={order.status} />
  </:col>
  <:col field={:total} type={:decimal} />
  <:col field={:placed_at} type={:datetime} label="Placed" />
</.data_grid>
```

Import the components in the `html_helpers` of your web module:

```elixir
import Masu.Components
```

A grid of a list is the same, with `rows`:

```heex
<.data_grid id="users" rows={@users} label="Users">
  <:col field={:name} />
  <:col field={:email} />
</.data_grid>
```

The grid keeps the person's order, filters and search while the LiveView
changes its rows: give it new `rows`, or a new query, and it shows them
in the same order.

## Guides

* [Quickstart](guides/quickstart.md): install, a grid of a list, then of
  an Ecto query.
* [Columns](guides/columns.md): fields, types, widths, and cells of your
  own HEEx.
* [Sources](guides/sources.md): lists, Ecto queries and schemas, and
  sources of your own.
* [Filters](guides/filters.md): the menu of each column, the values of
  an enum, and the filters of the LiveView.
* [Editing](guides/editing.md): cells saved through your changeset, or
  your own functions of a `Masu.Write`; paste, fill down and undo.
* [Editors of your own](guides/editors.md): a form of HEEx in a popover
  (Kotoba, Koyomi, a search of the server) or an editor of the
  browser's, for a column's cells.
* [Kotoba](guides/kotoba.md) and [Koyomi](guides/koyomi.md): rich text
  and pickers of dates, times and ranges in cells, and a picker that
  filters the grid.
* [Live rows](guides/live.md): a grid that follows a PubSub topic.
* [Collaboration](guides/collaboration.md): who else has the grid open,
  and where they are.
* [History](guides/history.md): who changed a cell, when, from what;
  restoring a value, or someone's paste; a store of any Ecto repo.
* [Layout and views](guides/views.md): pinned, hidden and moved columns,
  and each person's view in the URL and in a store.
* [Trees and details](guides/trees.md): rows in a tree, and rows that
  open on a detail of their own.
* [Groups and totals](guides/groups.md): rows grouped by columns, with
  their counts and totals, and a row of totals.
* [Export, selection and large tables](guides/export.md): CSV and XLSX,
  selecting rows and every row of a query, paging by key.
* [Actions](guides/actions.md): actions of your own on the rows
  selected and on each row, and actions that go on in a job.
* [Menus of your own](guides/menus.md): items in the header menus, and
  a menu on each cell.
* [Keyboard and copy](guides/keyboard.md): the keys, the selection, and
  what a copy gives.
* [Testing](guides/testing.md): `Masu.Test` with `Phoenix.LiveViewTest`.
* [Theming](guides/theming.md): the `--masu-*` properties and the Sumi
  theme.
* [Accessibility](guides/accessibility.md): the roles and the keyboard.
* [Known limits](guides/limits.md).

## Development

The grid's source is TypeScript in `assets/`. The built files in
`priv/static` are not in the repository; the Hex package has them.

```sh
mix deps.get
mix masu.build    # npm ci in assets/ when necessary, then esbuild
mix dev           # the development server on http://localhost:4099
```

`mix masu.build` runs in the `:dev` environment and needs `npm`. It
empties `priv/static` and writes the four files of the package:
`masu.esm.js`, `masu.cjs.js`, `masu.css` and `masu-sumi.css`.

`mix dev` runs `dev.exs`: a Phoenix endpoint with a grid of a hundred
thousand made-up customers (`/`), the smallest grid (`/small`), two
thousand quotes whose prices change live (`/live`), twenty customers
that every browser shares, to edit together (`/together`), and to
comment on (`/comments`), and the
Sumi theme at `/?theme=sumi` (and `&dark=1`), or in one of Sumi's seven
themes at `?sumi=smoke` (the links under the menu). Every page takes a
`locale` query param. Set `PORT` for another port. An esbuild watcher
rebuilds the bundle, and the page reloads.

### Tests

```sh
mix test                   # the ExUnit suite
mix test --include build   # also mix masu.build and mix hex.build
mix test.js                # the unit tests of the TypeScript modules
mix test.e2e               # the Playwright browser tests
mix precommit              # compile, format, credo --strict and test
mix dialyzer
mix bench                  # the benchmarks (bench/README.md), with PostgreSQL
```

The ExUnit suite tests the Ecto source on SQLite, in a file of its own,
with no setup. `MASU_DB` runs it on PostgreSQL or MySQL instead, in a
`masu_test` database (and `masu_test_history`) that each run drops and
creates again. `docker-compose.yml` has both servers:

```sh
docker compose up -d
MASU_DB=postgres mix test
MASU_DB=mysql mix test
```

`MASU_DB_URL` points to another server, for example
`ecto://user:pass@localhost:5432/masu_test`. CI runs the suite on all
three.

`mix test.js` runs the
tests of the pure modules in `assets/test/` (the block cache, the
geometry of the rows and the keys, the sort, the copied text and the
formats) with Node's test runner.

The browser tests in `e2e/` use Playwright, in Chromium, Firefox and
WebKit (the engine of Safari). Install the browsers once:

```sh
cd e2e && npm ci && npx playwright install chromium firefox webkit
```

`mix test.e2e` runs every spec in the three browsers, and `E2E_BROWSERS`
picks some of them. It runs `npm ci` in `e2e/` when `e2e/node_modules`
is missing, builds the bundle, and starts its own development server,
without watchers, on port 4098 (set `E2E_PORT` for another port). A
`mix dev` on port 4099 can keep running.

### Release

`mix release` (in this repository, an alias that replaces Mix's `release`
task) builds the bundle, checks that `priv/static` holds only the four
bundle files (`mix masu.release_check`), publishes to Hex, and tags and
pushes `v<version>`.

## Contributing

See [CONTRIBUTING.md](https://github.com/hattoriai/masu/blob/main/CONTRIBUTING.md): when a change needs an issue
first, and what a pull request needs. Report a security problem
privately, as [SECURITY.md](https://github.com/hattoriai/masu/blob/main/SECURITY.md) says.

## License

Masu is released under the MIT License. See `LICENSE`.
