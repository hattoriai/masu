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
| `--masu-header-background`, `--masu-header-text` | the header |
| `--masu-row-hover` | a row under the pointer |
| `--masu-selection`, `--masu-active` | a selected range, and the line of the active cell |
| `--masu-accent`, `--masu-accent-text`, `--masu-focus-ring` | the focus |
| `--masu-loading` | the bars of a row that is coming |
| `--masu-radius`, `--masu-cell-padding`, `--masu-space`, `--masu-field-height` | shape and space |
| `--masu-transition` | the speed of the small transitions |

The grid sets `--masu-cols`, `--masu-width` and `--masu-row-height` on
itself: the widths of the columns and the height of a row (the
`row_height` attribute).

## Dark mode without Sumi

Set the colours for your dark theme:

```css
[data-theme="dark"] .masu {
  --masu-text: #ececef;
  --masu-muted: #9a9aa5;
  --masu-background: #17171a;
  --masu-surface: #1f1f23;
  --masu-border: #33333a;
  --masu-rule: #26262b;
  --masu-row-hover: rgba(255, 255, 255, 0.04);
}
```

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
| `.masu-toolbar`, `.masu-search` | the search box |
| `.masu-grid` | the scroll box, with the grid role |
| `.masu-head`, `.masu-header`, `.masu-hcell` | the header |
| `.masu-sortable`, `.masu-sort`, `.masu-resizer` | a header that sorts, its mark, and its edge |
| `.masu-body`, `.masu-row`, `.masu-cell` | the rows and cells |
| `.masu-align-start`, `-center`, `-end`, `.masu-type-<type>` | a cell's alignment and type |
| `.masu-active`, `.masu-selected`, `.masu-col-selected` | the active cell, a selected cell, a header of a selected column |
| `.masu-loading`, `.masu-null`, `.masu-empty` | a row that is coming, an empty value, the grid with no rows |
| `.masu-busy`, `.masu-resizing` | a query being applied, a column being resized |
| `.masu-filter-button` | the funnel of a header; `[data-active]` when its column is filtered |
| `.masu-menu`, `.masu-menu-op`, `.masu-menu-input`, `.masu-menu-value`, `.masu-menu-count`, `.masu-menu-apply` | the filter menu |
| `.masu-chips`, `.masu-chip`, `.masu-chip-text`, `.masu-chip-remove`, `.masu-chips-clear` | the filters above the grid |
| `.masu-changed` | a row that changed on the grid's topic, for a moment (see [Live rows](live.md)) |
