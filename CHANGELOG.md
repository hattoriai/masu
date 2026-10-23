# Changelog

All notable changes to Masu are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Masu follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

On Issho 0.4.

### Changed

- Requires `{:issho, "~> 0.4"}`, with Issho (it is optional). Nothing
  changes in a grid's `issho`.

### Added

- Comments on a grid: Issho's comments (`Issho.Components.comments/1`)
  go on a cell or a range, and their marks on its cells, in each
  person's order. `Masu.Issho.label/2` says a grid's place in words
  ("City of Acme", "Name to City of Acme", "City of 3 rows"), for the
  panel's `:place` slot. The development app's `/comments` page. See the
  Collaboration guide.
- An agent that a person paused or stopped (`Issho.Work`) changes a grid
  no more: `select_cells`, `edit_cells`, `add_rows` and `delete_rows`
  say who and what to do, as Issho's tools do; `read_grid` still reads.
  An edit of many cells, one by one, stops at the cell it is on.

## [0.5.0] - 2026-10-22

On Issho 0.3: following and agents' motion are the room's.

### Changed (breaking)

- Following is Issho's, a room's: the grid's avatars, the page's people
  list (`Issho.Components.people/1`) and every block of the room follow
  the same person; the grid shows their view, the canvas beside it their
  viewport, the text their caret. Scrolling or a key in the grid stops
  following in the room. A grid alone on a page follows within itself, as
  before (Issho's contract: `data-issho-following` and the
  `issho:following` event, with no import of Issho's script). See the
  upgrade guide.
- An agent goes to a cell and "types" there for `pace` before the value
  lands (it saved, then waited). It moves with `Issho.Motion`: only when
  someone of the room sees the grid, within a tool call's time budget;
  Issho's `travel: false` turns it off for every component.
- Marks glide and ranges sweep only for a person who wants motion, as the
  app says it (Issho's `data-issho-motion`), else the browser's setting.
- Requires `{:issho, "~> 0.3"}`.
- A grid joins with `issho`'s keys of every component (`Issho.Join`:
  `:instance`, `:document`, `:can`, `:people`, `:follow`, `:on_behalf_of`,
  `:claims`) and Masu's `:actor`: `issho={[instance: MyApp.Issho,
  document: "notebook:42/tasks"]}`. `:room` (and this version's `:grid`)
  and the `people` and `follow` attributes are removed, and raise with
  what to write instead; an unknown key raises.
- Masu's own keys of a person's state are under the grid's document, in
  `"blocks"`, not in a top-level `"masu"`; Issho owns the top-level keys.

### Added

- A write's author: `Masu.Write`'s `by`, an `Issho.Identity` on a grid
  with `issho` and for an agent's tools (the agent and whom it acts for),
  else the grid's `user`. Every callback (`on_update`, `on_create`,
  `on_delete`, `on_restore`) has it. `Masu.Sheet` takes `by`.
- Each saved write of a grid with `issho`, or of an agent, emits
  `"document.changed"` in the room (`Issho.Events`), with `by` and
  `data: %{op:, count:}`.
- A place in a grid has a documented format, part of the API
  (`Masu.Issho.Place`: a cell, a range, a pointer in a cell).

- A grid in a document (a Kotoba embed, see the "In a document" guide):
  `height="auto"`, as tall as its rows up to `max_height`; `wheel={:page}`,
  the wheel the page's until the person is in the grid; and `view`, the
  view it opens with (a saved view's params).
- A grid in a document of another room (a Kotoba document): `issho`
  takes its `document`, the same wherever it is, so that an embed and the grid's
  own page are one grid; on a page without Issho's pointers of its room,
  the grid shares its person's pointer over a cell and draws the
  others'; the copy of a grid in use says where its person is when a
  page has it twice; a grid that goes while its LiveView stays releases
  its room and takes its place with it; following from its avatars
  brings it into view. See the Collaboration guide.
- `Masu.Snapshot`: a grid's rows as they are now, in a view, as a
  Markdown or an HTML table, with how many more: a document exported with
  a grid in it, an email of it.
- An agent moves as a person does: it goes to each cell it edits, types
  in it (`pace`, the milliseconds it is there before the value lands),
  and selects a range as a drag does, pressed on its first cell; it
  selects rows a moment before it deletes them. Only where it goes is
  sent, and each browser draws the way. `config :masu, Masu.Issho,
  travel: false` for changes that land at once.
- A person's mark glides from cell to cell, longer the farther it goes
  (up to 400ms; `--masu-peer-glide` for a fixed time), and a range
  selected from a cell sweeps over its rows (`--masu-sweep`, 350ms); none
  of it with reduced motion.
- An agent's page pointer (`Issho.Components.pointers/1`) goes to its
  cell or range: the grid says where they are on the page.
- A person's page pointer over a cell is that cell (Issho's `point`: its
  row's id, its column's key, and where in it): each page draws it on
  that cell, whatever its order or scroll.
- `follow={false}`: a grid that takes no part in following, though its
  room's other blocks do (its avatars are not buttons, and its view stays
  its person's).
- The following banner and ring are in Issho's look of following, the
  same on every block of the page, restyled with Issho's
  `--issho-following-background`, `--issho-following-text` and
  `--issho-following-ring`.

### Fixed

- A shared grid that goes with its page (a navigation) throws no error:
  it let its room go through a LiveView already gone, whose promise no
  one awaited.

## [0.4.0] - 2026-10-21

### Changed (breaking)

- A grid's people are those of an Issho room: `issho` takes the place of
  `presence`, which raises and says what to give instead, and
  `Masu.Presence` is gone. Their cells, ranges, the cell each edits (a
  lock of the room) and their views (for following) are in the room's
  awareness, their colors Issho's; agents are among them. A grid without
  people, and `live` rows, are unchanged. Why, and the steps: the
  [Upgrading to 0.4](guides/upgrading.md) guide.

### Added

- `Masu.Issho`: agents in a grid, in an Issho room. `Masu.Issho.tools/0`
  reads a grid (in an order, filtered, searched), points at cells, edits
  cells, adds and deletes rows, the grid's way (`Masu.Sheet`), under the
  room's policy; the people see the agent's cell, and its rows flash in
  its color. An agent leaves a cell that someone is editing. Issho is an
  optional dependency.
- `people={false}` hides the avatars above the grid, for a page that
  lists its room's people itself.
- `Masu.Sheet`: a grid outside the LiveView, for a job, a test or an
  agent. Define a grid once as `data_grid`'s attributes
  (`<.data_grid {MyApp.Grids.tasks(@current_scope)} />`), and
  `Masu.Sheet.new/1` of the same reads its rows in an order, filtered and
  searched, and edits, adds and deletes them the grid's way: its
  changeset or `on_update`, its read-only rules, the compare of a cell
  changed meanwhile, its history, and its `live` topic, so the people
  who have the grid open see each change, in the color of who made it.
- `views_scope`: whose views a grid's views are, such as the account's
  id. The store keeps each scope's views apart (under `"orders@42"`), so
  a view shared in one account is not offered in another. Without it,
  every account has the grid's one pool, as before.
- `create_with`: fields every new row gets, as a map or keyword list
  (`create_with={[account_id: @current_scope.account.id]}`). The grid
  puts them on `struct` before the changeset and on the changeset after
  it, so params cannot change them, and a column of one of these fields
  neither takes a value on a new row nor edits.
- A `read` of your own gets `seek` with the block: for a jump, `seek.()`
  gives the sort values of the row before the block, as `after` does,
  from one query of the sort values only. `after_row || seek.()` reads a
  jump by key too (#53).

### Changed

- Every error the grid shows a person is a sentence, with a capital and a
  full stop: "The filter contains is for text, not integer.", "A query
  has more than 100 filters.", "There is no column \"nope\"." The errors
  of a query were lowercase, without one. They are also the errors of
  `Masu.Filter.cast/2` and `Masu.Query.new/2`, and of the `ArgumentError`
  of a grid whose own `filters` do not check: a test or a log that matches
  on their text needs the new text. A view that is no longer there says
  "This view no longer exists." (it said "no such view").

- What the browser sends is bound where it comes in, and refused past
  the bound, never cut short (see "What the browser may send" in the
  limits guide): a search, the search of a column's values and the text
  of a filter value of at most 1,000 bytes; at most 100 filters, 100 sorts
  and 100 groups in a query; at most 10,000 values in a list filter; a
  view's name of at most 255 bytes. Texts are counted in bytes.
  - An event answers with an error ("The search is longer than 1,000
    bytes."), and `Masu.Filter.cast/2` returns one, also for the grid's
    `filters`. The search of a column's values gets no values.
  - A link or a saved view drops a part past a bound, whole, and says so
    ("Part of this view no longer applies: search"), as it does for a
    column that is gone.

- The browser asks for no rows while rows it asked for have not come
  (for ten seconds at most), and then for the rows on the screen: a drag
  of the scrollbar no longer reads the rows of each place it paused at
  (#53).

- A jump of an Ecto source (the scrollbar dragged to rows the grid did
  not read) counts its `OFFSET` over the sort values of the rows, not
  the rows, from the nearest block before it that the grid read, and
  reads the block by key. With an index of the sort's columns, the
  database reads only the index: on PostgreSQL, a jump to the middle of
  ten million rows sorted by a date takes 0.2 s, not 12 s (minutes from
  the disk), and a jump of 1,000 rows on from a block 1 ms (#53).

### Fixed

- A view's name was checked against its bound of 255 bytes before it was
  trimmed, and saved trimmed: a name with spaces around it that took it
  past the bound was refused, and a name of only spaces past it was "too
  long" rather than "A view needs a name." The name is now trimmed first,
  and checked as it is saved.

- An id from the browser that the source could not read crashed the
  LiveView: an integer key sent `"abc"` raised `Ecto.Query.CastError`,
  and a text or UUID key with a NUL reached PostgreSQL, which rejects it.
  Every id an event names (an edit, paste, fill or undo, a delete, a
  selection, a row's action, detail, history or editor, a locate) is now
  checked before a source reads it: a number, or a text of at most 1,000
  bytes without a NUL; an Ecto source also casts it with its primary
  key's type and dumps it as its repo's adapter does (a `:binary_id` on
  PostgreSQL is a UUID). An id that does not check is a row not found. A
  source of your own may check its ids with the new optional callback
  `id?/2` of `Masu.Source`.
- A search, a text filter or the search of a column's values on a field
  that is not stored as text failed on PostgreSQL ("function
  lower(bigint) does not exist"): a column without a `type` is of text,
  and searched, whatever its field. An Ecto source now casts such a field
  to a text first, as each database casts (Ecto's `type/2`); a field of
  text stays `lower(field)`, which an index serves.
- A text with a NUL character crashed the LiveView: PostgreSQL rejects
  `\u0000` in the jsonb of the last view the grid keeps (`views`), and the
  grid matched on `:ok`. A NUL is now refused in the texts the browser
  sends to a query, a view or a cell: the search and the filters of a
  query, a link or a saved view (that part is dropped), the name of a
  view, and an edited or new cell (that cell is refused). The history
  asks its store only for the key of a column, and for a batch token the
  grid could have made.

## [0.3.0] - 2026-10-20

### Added

- Columns of related rows: a `:col`'s `field` may be a path of
  associations to a field, `field={[:customer, :name]}`. Its key is
  `"customer.name"` and its label "Customer name" unless given.
  - A path of `belongs_to` and `has_one` is one value. An Ecto source
    sorts, filters, searches, groups and totals by it, and counts its
    values for the enum menu. It adds a `LEFT JOIN` for each step only
    when one of these needs it, as a named binding (`:customer`,
    `:customer_company`), and uses a binding of that name that the
    query already has. The source preloads the paths' associations, so
    that the blocks are still read by key. A list follows the path in
    each row.
  - A path through a `has_many` or `many_to_many` is of many values: a
    list in each cell, shown apart ("gift, urgent"). It filters by "has
    any of" (`:in`), "has all of" (`:all_of`), "has none of"
    (`:none_of`), "has none" (`:is_nil`) and "has some" (`:not_nil`). An
    Ecto source runs these as subqueries of the related rows, never as
    joins, so that no row repeats and the count stays right. The search
    finds a row by any of its values. Such a column does not sort or
    group, and its enum menu counts the rows that have each value.
  - Columns of related rows are read-only. A selection of every row
    that filters by one is a query of the schema's rows by their keys,
    so that an `update_all` of it runs in PostgreSQL, MySQL and SQLite.
  - `Masu.Column.path?/1`, `Masu.Column.many?/1`, `Masu.Filter.many_ops/0`,
    the optional `c:Masu.Source.many?/2`, and the column attribute
    `many`.
  - The messages `op_in_many`, `op_all_of`, `op_none_of`,
    `op_is_nil_many`, `op_not_nil_many`, `filter_none` and
    `filter_some`.
- Groups that start open: `expanded={:all}` on a grouped grid opens
  every group at every level, and `expanded={[:status]}` the groups of
  the columns it names. A group the person closes stays closed, with a
  new filter or view too; the groups of a column grouped from the
  header menu start open by the same rule.

### Changed

- A source of your own without `c:Masu.Source.supports?/2` does not sort
  or filter by a column of a related row's field. Its other columns
  work as before. A controlled grid (`on_query`) sorts and filters by
  every column, paths too: its LiveView gets the path's key.
- An Ecto source names its query's first binding `:masu`, unless the
  query names it, so that the conditions on its fields and on joined
  fields take their types.

### Fixed

- A selected cell of a pinned column shows the selection on every second
  row and on chosen rows, not the row's tint (#45).
- A menu or panel that floats (a cell's menu, a header menu, a panel, the
  history, a cell editor) is as tall as its content, whatever height the
  app's styles give popovers: it no longer stretches to the bottom or the
  top of the window (#44).
- With no more groups, no cell of the first column keeps a group's
  indent (#49).

## [0.2.0] - 2026-10-19

### Changed

Breaking: every write goes through a `Masu.Write`, and the functions
that write rows your way take one.

- `on_update`, `on_create`, `on_delete` and `on_restore` take the place
  of `update`, `create`, `delete` and `restore`. Each is a function of a
  `Masu.Write`, a batch of changes (the cells of an edit, a paste or a
  fill; new rows; rows deleted or back) with the rows found again
  through the grid's query, the read-only and stale cells already
  refused, what the person did (`origin`), the grid's `scope`, and a
  `ref`. It gives the write back with a result for each change:
  `Masu.Write.each/2` (row by row), `all/2` (the whole batch, an
  `Ecto.Multi`), `ok/3`, `error/3`, `save/1` (the grid's own way, which
  your function may wrap), or `async/1` (later, by a job).
- `on_save` is gone, and `on_delete` writes: hear of what was saved in
  your `on_update` (`Masu.Write.saved/1`). A grid that has one of the
  old attributes raises, naming the new one.
- A grid with `on_delete` undoes a delete only with `on_restore`
  (`on_restore={&Masu.Write.save/1}` when the rows delete the grid's
  way).
- The items of `:header_action` and `:cell_action` get `scope` and `ref`
  in their context, and their results are said: `{:ok, message}`,
  `{:error, message}`, `:async`.
- An Ecto source's rows of equal values in a descending sort come in
  the descending order of the primary key, not the ascending: the
  primary key that ends the order goes the way of the last sort, so that
  an index of the sorted column and the primary key reads the rows in
  their order, forwards or backwards.
- A search of a grid of rows (`Masu.Source.List`) makes a text of each
  row once, at the first search, and matches in it: each search after it
  is about eighteen times faster (a hundred thousand rows: from 491 ms to
  27 ms). The texts stay until the rows or the searchable columns change.

### Added

- The history of cells (`history` on a grid, `Masu.History`): who
  changed a cell, when, from what to what, and what they did (typed,
  pasted, filled, restored); new and deleted rows too. Every write of the
  grid that saves is recorded, the grid's own and an `on_update`'s;
  `Masu.Write.record/3` records in a transaction of the app's own, and
  `Masu.History.record/2` what the app changes another way. A batch is
  one write (a paste).
- Stores: `Masu.History.Ecto` (`use Masu.History.Ecto, repo: ...`), a
  table of any Ecto repo, PostgreSQL, MySQL or SQLite, with
  `mix masu.gen.history` for its migration: in the grid's own repo, a
  change and its record are saved in one transaction (a record that
  fails takes the change back); in a repo of its own (a SQLite file next
  to a PostgreSQL app), the change is recorded after it saves.
  `Masu.History.Memory` for development and tests; a store of your own
  over your audit.
- The history of a cell or a row in a popover, from the cell's menu or
  Ctrl+Alt+H: Restore a value, Undo all of a batch (someone's paste), as
  edits through the changeset, refused for a cell that changed since,
  recorded as restores.
- `Masu.Test.history/4` and `restore/3`.
- Editors of your own (`editor` on a `:col`), with no dependency of
  Masu's on any editor:
  - a function component of a form field (`@field`, named
    `cell[value]`), which the server renders in a popover under the
    cell, with the row as the source reads it now: what its form posts
    is the new value, text or params (`from` and `to`), cast by the
    changeset. A Kotoba editor or a Koyomi picker is one component, and
    a `Phoenix.LiveComponent` in it searches the server. Ctrl+Enter or a
    submit saves, a click away saves, Escape lets it go (after the
    editor's own Escape); an edit carries a version of the value it
    opened with, and a cell changed meanwhile is refused;
  - an editor of the browser's, by name, given to `configure({editors})`
    in the app's JavaScript, with options of the column
    (`editor={{"score", %{max: 100}}}`): it draws in a box over the
    cell, and the grid keeps Enter, Tab, Escape (unless the editor
    prevents them) and a click away.

  Either way the grid keeps undo and redo, the errors on the cell, "Ada
  is editing", and paste, fill down and Delete through the column's type.
- `Masu.Wire`: a protocol for values of your own types, as a cell shows,
  copies and exports them (a rich text's text, a range of days).
- `Masu.Test.open_editor/4` and `close_editor/2`; `edit/4` takes the
  params of an editor's form.
- Guides: [Editors of your own](editors.md), and how to plug in
  [Kotoba](kotoba.md) (rich text in cells) and [Koyomi](koyomi.md)
  (pickers in cells, and a picker above the grid that filters it through
  its URL), with no dependency of Masu's on either.
- `:action`: actions on the rows selected (`selectable`), buttons of
  the bar above the grid, with the selection as `Masu.Live.selected/1`
  gives it (`{:query, query}` for every row of the query), `confirm`
  ("Delete {count} orders?"), `danger` and `keep_selection`; the grid
  reads its rows again when one is done, and clears the selection.
- `:row_action`: actions on a row, in a menu at the end of each row
  (and in the menu of its cells: a right click, the context-menu key,
  Shift+F10), as a function, an event to the LiveView, or a link
  (`navigate`, `patch`); `show` and `disabled` by the row, read again on
  the server; `editors` in the context, the people editing the row.
- `scope` on the grid: in every write and every action's context.
- `Masu.reply/2` and `Masu.progress/3`: a write or an action that goes
  on in a job (`Masu.Write.async/1`, `:async`) says how far it is and
  how it went, from any process; the grid shows it running, its
  progress, and its result.
- `Masu.Test.action/3`, `row_action/4`, `actions/3` (`:selection`) and
  `actions/4` (`:row`); `origin:` for `edit/4`, `add_rows/4` and
  `delete_rows/4`, which give `:async` for a write saved later.
- Messages: `row_actions`, `action_done`, `action_running`,
  `action_progress`, `saving_later`, `deleting_later`.
- `read` on a grid of an Ecto source: a read of a block of rows of the
  app's own, a function of the query (with the grid's filters, search
  and order) and `%{offset:, limit:, order:, after:}`, `after` the sort
  values of the last row of the block before. The rest of the source
  (filters, count, values, selection, export) stays Masu's.
- `count_limit` on a grid of an Ecto source: the count stops after the
  row past the limit, and the grid says it has at least that many
  ("10,000+"), then counts every row when the person goes to the end. A
  `count(*)` of a large table reads every row; with more rows than the
  limit, the count is done after the limit. A query of fewer rows than
  the limit is still read whole, and PostgreSQL then reads it in one
  process, not in parallel: it can take longer than a `count(*)`.

### Fixed

- A grid that reads in tasks (`load={:async}`) reads the block after a
  block by key, as an inline grid does, not by `OFFSET`.
- An Ecto source keeps the keys of its blocks in its state, not in the
  LiveView's process dictionary, where the keys of every query before
  stayed for as long as the LiveView lived.
- With an adapter whose order of `NULL`s Masu does not know (not
  PostgreSQL, MySQL, SQLite or SQL Server), a sort other than the primary
  key's is read by `OFFSET`: by key, it took the order of SQLite's and
  could skip or repeat rows.
- The README and the guides said each block of an Ecto source is a
  `LIMIT` and `OFFSET`.
- A grid taller than a browser draws an element scrolls to its last
  row: Firefox did not scroll a grid of more than about 500,000 rows (of
  36 pixels) at all, and Chromium and Safari did not show the rows after
  about 930,000. The scroll box of such a grid is 10,000,000 pixels
  tall; the scrollbar dragged moves in proportion, and a wheel and the
  keys move by their own pixels.
- An undo (or a redo) right after an edit, before the server answered
  it, did nothing: it waits for the answer now, and takes the edit back.
- In Safari, the Columns panel lost the focus at each click on a
  control: the control keeps it, as in the other browsers.

## [0.1.2] - 2026-10-18

### Added

- A cell's menu compares text (Greater than, Less than, At least, At
  most) when the column's filters, or its source's, name the
  comparisons: a SQL client's text compares in its order.

## [0.1.1] - 2026-10-18

### Added

- A column's own filters: `filters` on a `:col` (or a column of
  `columns`) limits its filters to those operators, as a source's
  `filters/2` does, for a controlled grid whose app runs fewer.

- `raw` on a column shows its values as the source gives them (`12345`,
  `2026-10-18T08:00:00Z`), not formatted for the locale; the column
  keeps its type for its alignment, filters and editor.
- A cell's menu filters by the cell's value as a bound (Greater than,
  Less than, At least, At most; After, Before... for dates and times) in
  a column of numbers or dates, and by a part (Contains) in a column of
  text, as far as the column's filters go.
- `Masu.Messages.defaults/0`: every word of a grid, the browser's
  included, so that an app in another language can translate them all
  and test that none is left in English. The words go to the browser
  apart from the grid's config (`data-masu-messages`), once.

### Fixed

- `height` is the whole grid's: the rows take the room the toolbar, the
  chips and the status line leave. A percentage (`height="100%"`) fills
  the grid's container; the rows had no height at all.
- Menus and panels float above the page (the popover top layer), under
  their header or cell, or over it when there is more room there, and
  inside the viewport: a box around the grid that hides its overflow no
  longer cuts them.
- Masu's buttons, fields and selects keep their look next to an app's
  form styles (Tailwind's preflight and `@tailwindcss/forms`, which came
  later and won).
- Tokens made of others (`--masu-active`, `--masu-focus-ring`,
  `--masu-header-background`...) follow a grid's own `--masu-accent`,
  `--masu-surface`...: set on a class of the grid, they stayed Masu's
  blue.
- A controlled grid (`on_query`) offers no "Group by": its app runs the
  query.

## [0.1.0] - 2026-10-17

### Added

- `Masu.Components.data_grid/1`: a virtualized data grid for LiveView,
  with a `:col` slot for each column and cells rendered by HEEx.
- Sources: a list of rows (`Masu.Source.List`) and an Ecto query or
  schema (`Masu.Source.Ecto`), which sorts, filters, searches and counts
  in the database. `Masu.Source` for your own.
- Sorting by several columns, filters (`Masu.Filter`) and a search box.
- Columns that resize, and fit their content on a double click.
- Keyboard navigation of the cells, a selected range, and copy of the
  range as tab-separated text that spreadsheets paste.
- Cells formatted for the locale: numbers, decimals, dates and times.
- `Masu.Test`, to read and query a grid in `Phoenix.LiveViewTest`.
- A filter menu on each column (the funnel of its header, or Alt+↓):
  the filters of the column's type, an enum's values with their counts
  (`c:Masu.Source.values/5`: a list in the LiveView, one `GROUP BY` for
  Ecto), and the filters as chips above the grid. `Masu.Test.values/4`.
- Editing: `changeset` (or `update`) on the grid, `editable={false}` on a
  column. A cell edits on a key typed, Enter, F2 or a double click, with
  an editor for its type; the edits of a row are saved together, through
  the changeset and the repo (or applied to a row of a list), and the
  changeset's errors go on their cells. Paste of tab-separated text, fill
  down, Delete, undo and redo. A row is found again through the grid's
  own query (`c:Masu.Source.fetch/3`). `Masu.Test.edit/3`.
- Read-only rows and cells by their state: `row_editable` on the grid,
  and `editable` as a function of the row on a column. The server
  refuses an edit of a read-only cell (with the row it finds again) and
  saves the row's other edits; the browser gets each row's read-only
  cells, which open no editor and have `aria-readonly`.
- Edits of a cell that changed meanwhile are refused: each edit carries
  the value the person saw (when the editor opened), compared on the
  server by the column's type, a compare-and-swap of each cell; the cell
  then shows its value now. An Ecto source compares and saves each row in
  a transaction that locks it (`SELECT ... FOR UPDATE` on PostgreSQL and
  MySQL), and takes `optimistic_lock/3`'s `Ecto.StaleEntryError` as the
  same refusal. `Masu.Test.edit/3` takes `{id, key, value, before}`.
- `on_save`: a function called with the saved rows, in the LiveView's
  process, for an audit, a flash or the LiveView's own assigns.
- Collaboration (`Masu.Presence`): `presence` and `user` on a grid with
  `live`. The others who have the grid open show as avatars (a `:person`
  slot draws them), each one's cell as a line in their color with their
  name (by row id and column key, whatever each person's order and
  filters), a cell someone types in as "Ada is typing" and locked for the
  others, and the rows they save flash in their color. `configure/1` of
  the bundle draws the labels; CSS for the rest.
- Following a person: a click on their avatar shows their view (order,
  filters, search) and keeps their place in it on the screen; Stop brings
  back one's own view and place, and taking over (scrolling, clicking,
  typing) keeps theirs, with "Back to your view". `share_view={false}`
  keeps a person's view to themselves; whoever follows them stays in
  their own order, and the grid finds the person's row in it
  (`c:Masu.Source.locate/3`, a `row_number()` window for Ecto;
  `Masu.Test.place/3`).
  Each person's selected range shows to the others in their color. A
  refused edit names who changed the cell: "Changed by Ada meanwhile."
- Export (`Masu.Export`): `export` adds an Export menu, CSV and XLSX
  (written with no library, zipped as it is written) of every row of the
  query, downloaded by the browser from the route `masu_exports` mounts
  (`Masu.Router`) as the rows are read, with a link good once, for five
  minutes; nothing of the file goes over the LiveView's socket.
  `Masu.Live.export/1` gives an app the export to write or stream
  anywhere. Selection: `selectable`
  boxes, Shift ranges, Ctrl and Space, and every row of the query at
  once, which `Masu.Live.selected/1` gives as an `Ecto.Query`;
  `on_select`. An Ecto source reads the next block by key, not by
  `OFFSET`. `Masu.Test.export/4`, `export_url/3`, `select/4`, `select_all/3` and
  `selection/2`.
- Theming to match an app's own look: tokens for the grid's box
  (`--masu-grid-border`, `-radius`, `-shadow`), the header (its height,
  type, padding, border or shadow, hover), the rows (background, every
  second row's, the line under each) and a cell's hover; `.masu-row-even`
  on every second row; a row's hover over its own background; `density`
  (`:compact`, `:normal`, `:comfortable`); a dark palette under a `dark`
  class or `data-theme="dark"`; Tailwind in the Theming guide, and Lotus
  Web's results table as its worked example, compared pixel for pixel in
  e2e.
- Slow sources: `load={:async}` reads a source in a task (a new
  query's first rows and count, a block, a page, a count): the LiveView
  answers meanwhile, the grid says "Running…" with Stop and keeps its
  rows, `timeout` stops a long read, and a source's error (a raise, or
  `{:error, reason}` from `rows/3`, `Masu.Source.Error`) shows in the
  grid with Run again. `load={:inline}`, the default, reads as before.
- Controlled grids: with `on_query`, the LiveView runs its own queries;
  the grid shows the `rows` it is given (with `total` and `loading`),
  and reports the person's sort, filter, search, page and view. One sort
  at a time with `multi_sort={false}`. `Masu.Test` waits for tasks.
- Columns not known in advance, as a query tool's results: rows as
  lists of values (`field={2}` reads a place of a list), `type={:auto}`
  (the type of the values of the first block of rows), `columns` on a
  grid with no `:col` slots, and `c:Masu.Source.columns/1`. Rows of
  other columns keep the person's view of the columns there still and
  name the rest (`Masu.Query`'s sorts, filters and groups too); an
  order the person did not change follows the new columns.
  `Masu.Column.infer/1`.
- The filters a source runs: the optional `c:Masu.Source.filters/2`
  gives the operators a source filters a column by. The filter menu,
  the chips, the menu of a cell, a view's params and `Masu.Test.filter/3`
  offer only those, and the server refuses the others (a link's or a
  saved view's are dropped and named). Masu runs "between" as "at least"
  and "at most" for a source without it; an enum without "is one of"
  filters by one of its values. `Masu.Filter.ops/1`. The Sources guide
  maps each operator to SQL.
- Menus of your own (`Masu.Action`): `:header_action` items in each
  column's header menu, and a menu on each cell, opened by a right
  click, the context-menu key or Shift+F10, as an ARIA menu. `cell_menu`
  gives it copy, copy with headers, filter by the value, exclude it,
  empty and not empty, and sort; `:cell_action` adds the app's items.
  An item runs a function (`on_action`), sends the LiveView `{Masu.Action,
  name, context}` (`event`), runs a JS command in the browser (`js`, after
  a `masu:action` event), or opens a panel of its content under the header
  or the cell; for some columns (`columns`, `types`, `show`). The context
  has the column, and the cell's row and value read from the source, and
  the range it is in. The server runs only the items the grid offers.
  `Masu.Test.actions/4`, `header_action/4`, `cell_action/6` and
  `close_panel/2`.
- Row ids: `row_id={:position}` knows rows by their place in the query,
  for a read-only grid of rows with no id; a grid that needs no ids does
  so for a row without one. A grid whose features need ids that stay
  (editing, new and deleted rows, selection, live rows, presence,
  details, trees) refuses `:position`, and a row without an id, saying
  which.
- Reads: `block_size` (100) is the rows of one read as the person
  scrolls, and `max_block` (500) the most of one read; a page
  (`paging={:pages}`) is one read, up to `max_block`, and the next page is
  not read ahead. The first render reads one block, which the browser
  keeps.
- Counts and pages: `count={:deferred}` counts after the first rows, in
  a task; `count={:none}` counts when the person goes to the end. A
  source's `count/1` may give `{:at_least, n}` or `:unknown`, and
  `rows/3` `{rows, count}`: the grid scrolls over the rows it read and
  grows, `aria-rowcount="-1"`, "1,000+ rows". An Ecto source counts only
  when asked. `paging={:pages}` and `page_size`: a page at a time, with a
  pager, the page in the view and the URL. `Masu.Test.count/2`,
  `ask_count/2`, `page/3`.
- New and deleted rows: `create` (or `changeset` with `struct`) adds a
  "+ New row" row, Ctrl+Enter and Insert; a new row is a draft until the
  person leaves it, with its errors on its cells; a paste past the last
  row offers to add the rest. `deletable` (`Repo.delete`, or out of a
  list; a function of the row says which) or `delete` deletes rows with
  Ctrl+Delete or from the selection bar, after a question; Ctrl+Z brings
  them back (`restore` for a grid with `delete`). New and deleted rows go
  to the grid's topic; `on_delete`. `Masu.Test.add_rows/3`,
  `delete_rows/3`, `restore_rows/3`.
- Editors: an enum edits with a list of its values (`values`, or a
  schema's `Ecto.Enum` field's), which narrows as the person types;
  `decimals` on a number column; a value the server would refuse (text
  in a number, a day that is not one) is caught in the browser.
- Groups and totals (`Masu.Group`): `aggregate` on a column (`:sum`,
  `:avg`, `:min`, `:max`, `:count`, `:count_distinct`, or a function of
  a list's rows) and a row of totals at the bottom; `group_by` and
  "Group by" in the header menu, with a chip, as part of the view. Groups
  open on groups and rows as a tree does, with their counts and totals,
  and sort by value or by a total. An Ecto source groups and totals in
  the database, a `GROUP BY` for each level that shows, and reads an open
  group's rows a block at a time. `Masu.Test.group/3`, `groups/3` and
  `totals/2`. A filter on a hidden column keeps its chip.
- Trees and details (`Masu.Tree`): `tree={:parent_id}` shows rows in a
  tree (a `treegrid`), opened and closed with their arrow, →, ← and `*`,
  as one list of the rows that are open: a tree of twenty thousand rows
  scrolls as a list does. Siblings sort among themselves, and a filter
  keeps its matches and their ancestors. Both sources take it; the Ecto
  source reads the children of a row when it opens. A `:detail` slot
  opens a row on anything rendered by the server under it (another
  `data_grid` too), with Alt+→/←, Alt+↓ into it and Escape out.
  `Masu.Test.nodes/3`, `expand/3`, `collapse/3`, `expand_siblings/3` and
  `detail/4`.
- Layout and views: `pinned={:start | :end}` and `hidden` on a `:col`;
  columns that move by dragging their header (or Alt+Shift+←/→), and a
  columns menu (`columns_menu`) to show, hide, pin and move them. A
  person's view (`Masu.View`: order, filters, search and `Masu.Layout`)
  goes into the URL with `url`, and into a store with `views`
  (`Masu.Views`: `Masu.Views.Ecto` with `mix masu.gen.views`, and
  `Masu.Views.Memory`): their last view comes back, and a views menu
  saves named views, shared or not. A view's parts that no longer apply
  are dropped, and the grid says so. `Masu.Test.view/2`,
  `apply_view/3` and `layout/3`.
- Live rows: `live={{pubsub, topic}}`, the `Masu.Live` hook, and
  `Masu.Live.broadcast_upsert/3` and `broadcast_delete/3`. A grid takes
  the changes of its topic into the person's query, a batch at a time;
  the browser keeps the scroll and the rows on the screen until the new
  ones come, and flashes the changed rows.
