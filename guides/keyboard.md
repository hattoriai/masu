# Keyboard and copy

A grid is one stop of the Tab key. Inside it, the keys move the active
cell, as in a spreadsheet.

## The keys

| Key | Does |
| --- | --- |
| ←, →, ↑, ↓ | moves one cell; ↑ from the first row goes to the header |
| Ctrl with an arrow (⌘ on a Mac) | moves to the edge of the grid in that direction |
| Home, End | the first or last cell of the row |
| Ctrl+Home, Ctrl+End | the first or last cell of the grid |
| Page Up, Page Down | a screen of rows up or down |
| Enter or Space on a header | sorts by its column; with Shift, by it too |
| Alt+↓ on a header | opens its filter menu; Escape closes it, and the focus comes back |
| →, ←, * on the first column of a tree | opens a row, closes it (or goes to its parent), opens every row beside it (see [Trees and details](trees.md)) |
| Space on the first column, Shift and a box, Ctrl and a click | selects rows, in a grid with `selectable` (see [Export, selection and large tables](export.md)) |
| Alt+→, Alt+← on a row | opens and closes its detail; Alt+↓ goes into it, Escape comes back |
| Alt+Shift+←, Alt+Shift+→ on a header | moves its column, among the columns of its pin (see [Layout and views](views.md)) |
| Shift with a move | selects the range from where the selection started |
| Ctrl+A | selects every row |
| Escape | drops the selection |
| Ctrl+C | copies the selection, or the active cell |
| A key typed, Enter, F2 | edits the active cell, in a grid that edits (see [Editing](editing.md)) |
| Ctrl+V | pastes tab-separated text from the active cell |
| Ctrl+D | fills the selection down with its first row |
| Delete, Backspace | empties the editable cells of the selection |
| Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y | undoes and redoes an edit |

In a grid that reads right to left, ← and → swap.

The mouse does the same: a click makes a cell active, a drag or a click
with Shift selects a range, and a click on a header sorts (with Shift,
by that column too).

↓ in the search box goes to the grid.

## What a copy gives

A copy gives tab-separated text, which every spreadsheet pastes into
cells: a line for each row, a tab between the cells, and quotes around a
value with a tab, a line break or a quote.

It copies the values themselves, not their formatted text, so that a
spreadsheet reads numbers and dates as numbers and dates: `1234.5`, not
`1,234.5`; `2026-10-17`, not `17 Oct 2026`. A boolean is `TRUE` or
`FALSE`, and a cell of your own HEEx gives its text.

A copy of every row (Ctrl+A, then Ctrl+C) starts with the labels of the
columns.

A selection can be larger than the rows the browser has. The grid asks
the server for the rows it lacks, up to ten thousand of them, and writes
the clipboard when they come; a screen reader hears how many rows were
copied.
