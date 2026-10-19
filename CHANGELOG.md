# Changelog

All notable changes to Masu are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Masu follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Groups that start open: `expanded={:all}` on a grouped grid opens
  every group at every level, and `expanded={[:status]}` the groups of
  the columns it names. A group the person closes stays closed, with a
  new filter or view too; the groups of a column grouped from the
  header menu start open by the same rule.

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
