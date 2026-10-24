// The grid's header cells and the chips above it, as elements: the
// label, the sort's arrow and the menu's button of each column, and a
// chip for each filter and group, with the filter bar's Add filter.
// The grid owns what they do; these only draw them.

import type { ColumnConfig } from "./types";

export interface HeaderCellOptions {
  id: string;
  col: number;
  column: ColumnConfig;
  /** The column's place in the order: its direction, and its rank when there are several. */
  sort: { dir: "asc" | "desc"; rank: number | null } | null;
  /** The box that selects every row, on the first column of a grid that selects. */
  selectAll: { checked: boolean; indeterminate: boolean; label: string } | null;
  /** The button of the column's menu, at the end of the cell. */
  menu: { label: string; expanded: boolean; icon: "filter" | "more"; active: boolean } | null;
}

export function headerCell(options: HeaderCellOptions): HTMLElement {
  const { id, col, column, sort, selectAll, menu } = options;
  const cell = document.createElement("div");
  cell.id = id;
  cell.className = `masu-hcell masu-align-${column.align}${column.sortable ? " masu-sortable" : ""}${menu ? " masu-has-menu" : ""}`;
  cell.setAttribute("role", "columnheader");
  cell.setAttribute("aria-colindex", String(col + 1));
  cell.dataset.key = column.key;
  cell.dataset.col = String(col);

  if (selectAll) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "masu-select-all";
    box.tabIndex = -1;
    box.checked = selectAll.checked;
    box.indeterminate = selectAll.indeterminate;
    box.setAttribute("aria-label", selectAll.label);
    cell.appendChild(box);
  }

  const label = document.createElement("span");
  label.className = "masu-label";
  label.textContent = column.label;
  cell.appendChild(label);

  if (column.sortable) {
    const icon = document.createElement("span");
    icon.className = "masu-sort";
    icon.setAttribute("aria-hidden", "true");
    if (sort) {
      icon.dataset.dir = sort.dir;
      if (sort.rank !== null) icon.textContent = String(sort.rank);
    }
    cell.appendChild(icon);
    cell.setAttribute("aria-sort", sort && (sort.rank ?? 1) === 1 ? (sort.dir === "asc" ? "ascending" : "descending") : "none");
  }

  if (menu) {
    const button = document.createElement("button");
    button.type = "button";
    button.tabIndex = -1;
    button.className = "masu-filter-button";
    button.dataset.col = String(col);
    button.setAttribute("aria-label", menu.label);
    button.setAttribute("aria-haspopup", "dialog");
    button.setAttribute("aria-expanded", String(menu.expanded));
    if (menu.active) button.dataset.active = "true";
    button.innerHTML = menu.icon === "filter" ? FILTER_ICON : MORE_ICON;
    cell.appendChild(button);
  }

  const resizer = document.createElement("span");
  resizer.className = "masu-resizer";
  resizer.setAttribute("aria-hidden", "true");
  cell.appendChild(resizer);
  return cell;
}

/** A filter's chip: its column, its operator and its value, a button that opens the column's menu, and one that takes it away. */
export function filterChip(
  key: string,
  col: number | null,
  parts: { label: string; op: string; value: string | null },
  removeLabel: string,
): HTMLElement {
  const chip = document.createElement("span");
  chip.className = "masu-chip";
  const text = document.createElement("button");
  text.type = "button";
  text.className = "masu-chip-text";
  // A filter on a hidden column keeps its chip, which opens no menu.
  text.dataset.key = key;
  if (col !== null) text.dataset.col = String(col);
  else text.disabled = true;
  // Spaces between the parts: what a screen reader says, and what is copied.
  text.append(part("masu-chip-label", parts.label), " ", part("masu-chip-op", parts.op));
  if (parts.value !== null) text.append(" ", part("masu-chip-value", parts.value));
  const words = parts.value === null ? `${parts.label} ${parts.op}` : `${parts.label} ${parts.op} ${parts.value}`;
  text.title = words;
  chip.append(text, removeButton(`${removeLabel}: ${words}`, { key }));
  return chip;
}

/** A group's chip: the column the rows are grouped by, and a button that stops. */
export function groupChip(key: string, text: string, removeLabel: string): HTMLElement {
  const chip = document.createElement("span");
  chip.className = "masu-chip masu-chip-group";
  const label = document.createElement("span");
  label.className = "masu-chip-text";
  label.append(part("masu-chip-label", text));
  chip.append(label, removeButton(removeLabel, { group: key }));
  return chip;
}

/** The filter bar's button that adds a filter: a menu of the columns that filter. */
export function addFilterButton(label: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "masu-add-filter";
  button.setAttribute("aria-haspopup", "dialog");
  button.setAttribute("aria-expanded", "false");
  button.innerHTML = PLUS_ICON;
  const text = document.createElement("span");
  text.textContent = label;
  button.appendChild(text);
  return button;
}

/** The button that takes every filter away. */
export function clearAllButton(label: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "masu-chips-clear";
  button.textContent = label;
  return button;
}

function part(className: string, text: string): HTMLElement {
  const span = document.createElement("span");
  span.className = className;
  span.textContent = text;
  return span;
}

function removeButton(label: string, data: Record<string, string>): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "masu-chip-remove";
  Object.assign(button.dataset, data);
  button.setAttribute("aria-label", label);
  button.innerHTML = CLOSE_ICON;
  return button;
}

// Three dots, drawn for Masu: a header's menu (with the filter bar, or without a filter), and a row's actions.
export const MORE_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><circle cx="3.5" cy="8" r="1.25" fill="currentColor"/><circle cx="8" cy="8" r="1.25" fill="currentColor"/><circle cx="12.5" cy="8" r="1.25" fill="currentColor"/></svg>';

// A funnel, drawn for Masu.
const FILTER_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 3h11l-4.25 5v4.25l-2.5 1.25V8z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>';

// A plus, drawn for Masu: Add filter.
const PLUS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M8 3.5v9M3.5 8h9" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';

// A cross, drawn for Masu: a chip's button that takes it away.
const CLOSE_ICON =
  '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true" focusable="false"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
