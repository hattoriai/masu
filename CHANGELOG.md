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
- Live rows: `live={{pubsub, topic}}`, the `Masu.Live` hook, and
  `Masu.Live.broadcast_upsert/3` and `broadcast_delete/3`. A grid takes
  the changes of its topic into the person's query, a batch at a time;
  the browser keeps the scroll and the rows on the screen until the new
  ones come, and flashes the changed rows.
