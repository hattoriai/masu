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
- `on_save`: a function called with the saved rows, in the LiveView's
  process, for an audit, a flash or the LiveView's own assigns.
- Live rows: `live={{pubsub, topic}}`, the `Masu.Live` hook, and
  `Masu.Live.broadcast_upsert/3` and `broadcast_delete/3`. A grid takes
  the changes of its topic into the person's query, a batch at a time;
  the browser keeps the scroll and the rows on the screen until the new
  ones come, and flashes the changed rows.
