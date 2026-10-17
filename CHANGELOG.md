# Changelog

All notable changes to Masu are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Masu follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  (written with no library) of every row of the query, written in a task
  with progress and downloaded by the browser; `Masu.Live.export/1`
  gives an app the export to write anywhere. Selection: `selectable`
  boxes, Shift ranges, Ctrl and Space, and every row of the query at
  once, which `Masu.Live.selected/1` gives as an `Ecto.Query`;
  `on_select`. An Ecto source reads the next block by key, not by
  `OFFSET`. `Masu.Test.export/3`, `select/4`, `select_all/3` and
  `selection/2`.
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
