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
* sorting by several columns, a search box, and a filter menu on each
  column, with the values of an enum and their counts, and the filters
  as chips above the grid;
* columns that resize, and fit their content on a double click;
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
| Sources | `rows={@users}` for a list; `source={query} repo={Repo}` for Ecto, where a sort is an `ORDER BY`, a filter and the search a `WHERE`, and each block a `LIMIT` and `OFFSET`; `Masu.Source` for your own |
| Editing | `changeset={&Order.changeset/2}`: a cell edits on a key typed, Enter, F2 or a double click; the edits of a row saved together with `Repo.update`, the errors on their cells, the old values back; paste of tab-separated text, fill down, Delete, undo and redo; read-only rows and cells by their state (`row_editable`, `editable={&...}`), checked on the server; `update` for your own persistence and `on_save` to hear of each save; a row found again through the grid's own query |
| Live rows | `live={{MyApp.PubSub, "orders"}}` and `Masu.Live.broadcast_upsert/3`: changes come into the person's query, a batch at a time, the scroll stays, the rows do not blink, the changed ones flash |
| Columns | a field or a function of the row, a type, a width, an alignment; cells of your own HEEx, rendered on the server |
| Types | text, enums, integers, numbers, decimals (sent as text, so no digit is lost), dates, datetimes, times, booleans |
| Sorting | a click on a header; with Shift, by several columns, numbered in the headers; text without case, empty values last |
| Filters | a menu on each header with the filters of its type: contains, starts and ends with, greater and less than, after and before, between, empty; an enum's values ticked from a list with their counts (one `GROUP BY` in the database); the filters as chips; checked against each column's type on the server |
| Search | a search box over the text columns, in the list or in the database |
| Keyboard | the arrows, Ctrl with them, Home, End, Page Up and Down, the header row, Enter on a header to sort, Shift to select, ⌘A, Escape |
| Copy | ⌘C copies the range as tab-separated values, the values themselves (numbers and dates as a spreadsheet reads them), and asks the server for rows the browser lacks |
| Locales | numbers, decimals, dates and times in the grid's locale, with the browser's `Intl` |
| Theming | CSS custom properties, the Sumi theme, dark mode, reduced motion |
| Accessibility | the WAI-ARIA grid with one tab stop and the active cell as `aria-activedescendant`, row and column counts and indexes, `aria-sort`, announcements |

## Install

Masu needs Elixir 1.18 or later (it uses the built-in `JSON` module),
Phoenix 1.7.14 or 1.8, and Phoenix LiveView 1.1 or later. An Ecto
source needs Ecto 3.13 or later.

Add `masu` to the deps in `mix.exs`:

```elixir
def deps do
  [
    {:masu, "~> 0.1"}
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
* [Editing](guides/editing.md): cells saved through your changeset,
  paste, fill down and undo.
* [Live rows](guides/live.md): a grid that follows a PubSub topic.
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
thousand quotes whose prices change live (`/live`), and the
Sumi theme at `/?theme=sumi` (and `&dark=1`). Every page takes a
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
```

The ExUnit suite tests the Ecto source on SQLite. `mix test.js` runs the
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

## License

Masu is released under the MIT License. See `LICENSE`.
