# Theming

Every colour, space, radius and font of a grid comes from a `--masu-*`
custom property. Set them on `.masu` (or higher) to theme the grids:

```css
.masu {
  --masu-accent: #0f766e;
  --masu-font-size: 0.8125rem;
}
```

The defaults have no specificity, so a value set on `:root`, on an
ancestor or on `.masu` itself wins. They are Kotoba's and Koyomi's own
defaults, so that a page with all three looks like one thing.

## The properties

| Property | Is |
| --- | --- |
| `--masu-font`, `--masu-font-size`, `--masu-line-height` | the type |
| `--masu-text`, `--masu-muted` | text, and empty values |
| `--masu-background`, `--masu-surface` | the rows, and the surfaces |
| `--masu-border`, `--masu-rule` | the frame, and the lines between rows |
| `--masu-grid-border`, `--masu-grid-radius`, `--masu-grid-shadow` | the grid's box (a 1px `--masu-border` with `--masu-radius` unless set; `none` and `0` for a table without one) |
| `--masu-header-background`, `--masu-header-text` | the header (`--masu-surface` and `--masu-text` unless set) |
| `--masu-header-height` | the header's row (the rows' height unless set) |
| `--masu-header-font-size`, `--masu-header-font-weight`, `--masu-header-text-transform`, `--masu-header-letter-spacing` | the header's type |
| `--masu-header-padding` | a header cell's padding (the cells' unless set) |
| `--masu-header-border`, `--masu-header-shadow` | the line under the header, or its shadow |
| `--masu-header-hover` | a header cell under the pointer |
| `--masu-row-background`, `--masu-row-alt-background` | the rows, and every second row (zebra rows: the second, the fourth, as `:nth-child(even)` counts) |
| `--masu-row-border` | the line under each row (a 1px line of `--masu-rule` unless set; `none` gives a row its whole height) |
| `--masu-row-hover`, `--masu-cell-hover` | a row and a cell under the pointer, over the row's own background |
| `--masu-selection`, `--masu-active` | a selected range, and the line of the active cell (`--masu-accent` unless set) |
| `--masu-accent`, `--masu-accent-text`, `--masu-focus-ring` | the focus (a ring of `--masu-accent` unless set) |
| `--masu-loading` | the bars of a row that is coming |
| `--masu-invalid` | the line of a cell the server refused |
| `--masu-avatar-size` | the avatars of the others (Collaboration) |
| `--masu-radius`, `--masu-cell-padding`, `--masu-space`, `--masu-field-height` | shape and space |
| `--masu-transition` | the speed of the small transitions |

A changed row has the color of the person who saved it in
`--masu-flash` (the accent unless someone saved it). The grid sets
`--masu-cols`, `--masu-width` and `--masu-row-height` on itself: the widths of the columns and the height of a row (the
`row_height` attribute).

## Density

`density` sets the room around a cell's text: `:compact` (rows of 28
pixels), `:normal` (36) or `:comfortable` (48), and their padding.
`row_height` sets the rows' height itself.

```heex
<.data_grid id="orders" rows={@orders} density={:compact}>
```

## Dark mode

Masu follows the app's own switch: a `dark` class on an ancestor (as
Tailwind and Phoenix's generated apps put on `<html>`), or
`data-theme="dark"`. It does not follow the system's setting by itself,
so that a light app stays light; an app that does maps its own media
query to one of them.

Its dark palette is a neutral one. Set your own under the same switch:

```css
.dark .masu {
  --masu-text: #ececef;
  --masu-background: #17171a;
  --masu-surface: #1f1f23;
  --masu-border: #33333a;
  --masu-rule: #26262b;
}
```

## With Tailwind

Map the tokens to your theme's colors in `app.css`, once, for light and
dark:

```css
/* Tailwind 4 */
.masu {
  --masu-font: var(--font-sans);
  --masu-text: var(--color-zinc-800);
  --masu-background: var(--color-white);
  --masu-header-background: var(--color-white);
  --masu-row-alt-background: var(--color-zinc-50);
  --masu-accent: var(--color-indigo-600);
}

.dark .masu {
  --masu-text: var(--color-zinc-100);
  --masu-background: var(--color-zinc-900);
  --masu-header-background: var(--color-zinc-900);
  --masu-row-alt-background: var(--color-zinc-800);
}
```

With Tailwind 3, use `theme()`: `--masu-text: theme(colors.zinc.800)`.
`class` on the grid takes any class of yours, to scope a look to some
grids: `<.data_grid class="report-grid" ...>`.

## Make Masu look like your table

An app with tables of its own wants its grids to look like them. Measure
your table (a browser's computed styles of a header cell, a cell, an
even row), and set the tokens to the values. Lotus Web's results table,
in tokens, with `row_height={52}`:

```css
.lotus-results {
  --masu-font: "Inter var", sans-serif;
  --masu-font-size: 0.875rem;
  --masu-line-height: 1.25rem;
  --masu-text: rgb(39 39 42);
  --masu-background: rgb(255 255 255);
  --masu-header-background: rgb(255 255 255);
  --masu-header-text: rgb(39 39 42);
  --masu-header-height: 48px;
  --masu-header-border: none;
  --masu-header-shadow: 0 1px 0 0 rgb(209 213 219);
  --masu-header-hover: rgb(239 246 255);
  --masu-grid-border: none;
  --masu-grid-radius: 0;
  --masu-row-border: none;
  --masu-row-alt-background: rgb(249 250 251);
  --masu-row-hover: transparent;
  --masu-cell-hover: rgb(239 246 255);
  --masu-cell-padding: 0 0.75rem;
}

.dark .lotus-results {
  --masu-text: rgb(244 244 245);
  --masu-background: rgb(23 23 23);
  --masu-header-background: rgb(23 23 23);
  --masu-header-text: rgb(244 244 245);
  --masu-header-shadow: 0 1px 0 0 rgb(75 85 99);
  --masu-header-hover: rgb(30 58 138 / 0.2);
  --masu-row-alt-background: rgb(55 65 81);
  --masu-cell-hover: rgb(30 58 138 / 0.2);
}
```

In Lotus Web itself, the values would be its own variables
(`rgb(var(--lotus-gray-50))`), so that its themes apply. Masu's e2e
suite renders Lotus Web's table, with Lotus Web's own CSS, next to a
grid with these tokens, and compares them pixel for pixel, light and
dark, at rest and with a cell under the pointer (`e2e/specs/look.spec.ts`;
the dev server's `/look`).

## The Sumi theme

`masu-sumi.css` maps every property to the Sumi tokens, as
`kotoba-sumi.css` and `koyomi-sumi.css` do. Load it after `masu.css`:

```css
@import "../../deps/masu/priv/static/masu.css";
@import "../../deps/masu/priv/static/masu-sumi.css";
```

On a page with the Sumi themes, the grids follow them. Without them, the
built-in Sumi palette follows `data-theme` (`"dark"` or `"light"`), then
`prefers-color-scheme`. The selection is a faint wash of the blade, and
the active cell a line of it.

## Classes

| Class | Is |
| --- | --- |
| `.masu` | the grid's element |
| `.masu-density-compact`, `.masu-density-comfortable` | a grid's `density` |
| `.masu-row-even` | every second row (the second, the fourth), by its place in the query |
| `.masu-toolbar`, `.masu-search` | the search box |
| `.masu-toolbar-actions`, `.masu-toolbar-button`, `.masu-columns-button`, `.masu-views-button` | the toolbar's buttons (see [Layout and views](views.md)) |
| `.masu-pinned`, `.masu-pinned-start`, `.masu-pinned-end`, `.masu-pinned-edge` | a cell of a pinned column, and of the last (or first) one, which draws the edge; it sticks at `--masu-pin-<n>` |
| `.masu-moving`, `.masu-dragged`, `.masu-drop` | a column being moved: the grid, its header, and the line where it goes |
| `.masu-panel`, `.masu-columns-panel`, `.masu-columns-item`, `.masu-columns-pin`, `.masu-columns-move` | the columns menu |
| `.masu-views-panel`, `.masu-views-item`, `.masu-views-apply`, `.masu-views-shared`, `.masu-views-delete`, `.masu-views-form` | the views menu |
| `.masu-grid` | the scroll box, with the grid role |
| `.masu-head`, `.masu-header`, `.masu-hcell` | the header |
| `.masu-sortable`, `.masu-sort`, `.masu-resizer` | a header that sorts, its mark, and its edge |
| `.masu-body`, `.masu-row`, `.masu-cell` | the rows and cells |
| `.masu-align-start`, `-center`, `-end`, `.masu-type-<type>` | a cell's alignment and type |
| `.masu-active`, `.masu-selected`, `.masu-col-selected` | the active cell, a selected cell, a header of a selected column |
| `.masu-loading`, `.masu-null`, `.masu-empty` | a row that is coming, an empty value, the grid with no rows |
| `.masu-busy`, `.masu-resizing` | a query being applied, a column being resized |
| `.masu-has-menu`, `.masu-filter-button` | a header with a menu, and its button (**⋯**, or the funnel with `filter_bar={false}`; `[data-active]` then when its column is filtered) |
| `.masu-menu`, `.masu-menu-sorts`, `.masu-menu-sort`, `.masu-menu-op`, `.masu-menu-input`, `.masu-menu-value`, `.masu-menu-count`, `.masu-menu-apply` | a header's menu: its sorts (`aria-pressed` on the grid's), and the filter |
| `.masu-chips`, `.masu-filter-bar`, `.masu-chip`, `.masu-chip-text`, `.masu-chip-label`, `.masu-chip-op`, `.masu-chip-value`, `.masu-chip-remove`, `.masu-chips-clear` | the filters above the grid (`.masu-filter-bar` with the filter bar), each chip's column, operator and value; `--masu-chip-height` (1.75rem) |
| `.masu-add-filter`, `.masu-filters-panel` | the filter bar's Add filter, and its menu of columns (`data-filtered` on a column with a filter) |
| `.masu-editable`, `.masu-editor`, `.masu-saving`, `.masu-invalid` | a cell that edits, its editor, a cell being saved, a cell refused |
| `.masu-choices`, `.masu-choice` | an enum's editor: the list of its values, and each |
| `.masu-pager`, `.masu-pager-range`, `.masu-pager-previous`, `.masu-pager-next`, `.masu-pager-form` | the pager of a grid of pages |
| `.masu-add-row`, `.masu-draft` | the row "+ New row", and a new row not saved yet |
| `.masu-confirm`, `.masu-confirm-ok`, `.masu-confirm-cancel`, `.masu-danger` | a question above the grid (delete rows, add the rest of a paste), and an answer that deletes |
| `.masu-locked` | a cell that the row's state makes read-only, in a column that edits |
| `.masu-people`, `.masu-person`, `.masu-initials`, `.masu-people-more` | the avatars of the others; each has `--masu-peer-color` |
| `.masu-peer`, `.masu-peer-label`, `.masu-peer-editing`, `.masu-peer-top` | another person's cell, their name, while they type, on the first row; with `--masu-peer-color` |
| `.masu-peer-range` | another person's selected range, a row at a time; with `--masu-peer-color` |
| `.masu[data-following]`, `.masu-following`, `.masu-following-stop` | following a person: the grid (with `--masu-follow-color`; its `.masu-chip`s take the color), the banner (`data-kind`: `following`, `follow_hidden`, `their_view`), its button; the avatar has `aria-pressed="true"` |
| `.masu-content`, `.masu-details`, `.masu-detail` | the header and rows (the browser's), the open details (the server's), a detail |
| `.masu-tree-cell`, `.masu-twisty`, `.masu-detail-toggle` | the first cell of a tree's row (indented by `--masu-level` × `--masu-indent`), its arrow (`data-state`: `open`, `closed`, `leaf`), a detail's arrow (`data-open`) |
| `.masu-group-row`, `.masu-group-label`, `.masu-group-count` | a group's row, its label, its count |
| `.masu-foot`, `.masu-totals` | the row of totals at the bottom |
| `.masu-chip-group`, `.masu-menu-group` | the chip of a grouped column, the Group by button of the header menu |
| `.masu-select`, `.masu-select-all`, `.masu-row-chosen`, `.masu-selection-bar`, `.masu-selection-clear`, `.masu-selection-delete` | a row's box, the header's box, a row selected, the bar of how many, and its Delete |
| `.masu-export-button`, `.masu-export-panel`, `.masu-export-format` | the Export menu (`aria-busy` on its button while it asks for the link) |
| `.masu-changed` | a row that changed on the grid's topic, for a moment (see [Live rows](live.md)) |
