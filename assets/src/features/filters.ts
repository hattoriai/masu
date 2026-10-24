// The filters of the grid: the chips above it, the filter bar's Add filter,
// and the menu of each header, with its sorts, the app's items, Group by and
// the column's filter.

import { describeParts, replaceFilter, zoned } from "../filters";
import { formatter } from "../format";
import { addFilterButton, clearAllButton, filterChip, groupChip } from "../header";
import { FilterMenu } from "../menu";
import type { CellValue, ColumnConfig } from "../types";
import type { Grid } from "../grid";

/** Where a column's menu was opened: its header (null), or the filter bar: its chip (the filter's key), or Add filter (null). */
export type MenuFrom = null | { chip: string | null };

export class Filters {
  /** The chips of the filters, above the grid, in the browser's part. */
  readonly chipsEl: HTMLElement = document.createElement("div");
  /** The menu open: of a header, or the filter of a column opened from the filter bar (`from`: its Add filter, or the key of its chip). */
  menu: { col: number; menu: FilterMenu; from: MenuFrom } | null = null;
  /** The filter bar's Add filter (`filter_bar`). */
  addFilter: HTMLButtonElement | null = null;

  constructor(private readonly grid: Grid) {
    this.chipsEl.className = "masu-chips";
  }

  /** Whether the grid has the filter bar (`filter_bar`, the default): Add filter above it, and a menu of sorts and filter on each header. */
  filterBar(): boolean {
    return this.grid.config.filterBar !== false;
  }

  renderChips(): void {
    const messages = this.grid.messages();
    const groups = (this.grid.query.groups ?? []).flatMap((key) => {
      const column = this.catalogColumn(key);
      if (!column) return [];
      return [groupChip(key, this.grid.message("grouped_by", { label: column.label }), this.grid.message("ungroup_by", { label: column.label }))];
    });

    const chips = this.grid.query.filters.flatMap((filter) => {
      const col = this.grid.columns.findIndex((column) => column.key === filter.key);
      const column = col >= 0 ? this.grid.columns[col] : this.catalogColumn(filter.key);
      if (!column) return [];
      const format = col >= 0 ? this.grid.formatters[col] : formatter(column.type, this.grid.config.locale ?? undefined, null, column.raw);
      const parts = describeParts(filter, column, (value) => format(value as CellValue), messages);
      return [filterChip(filter.key, col >= 0 ? col : null, parts, messages.remove_filter)];
    });

    // The bar shows while a column filters, so that a filter can be added.
    const bar = this.filterBar() && this.grid.columns.some((column) => column.filterable);
    if (bar) {
      this.addFilter ??= addFilterButton(messages.add_filter);
      this.addFilter.querySelector("span")!.textContent = messages.add_filter;
    } else if (this.addFilter) {
      if (this.grid.toolbar.panel?.kind === "filters") this.grid.toolbar.closePanel(false);
      this.addFilter = null;
    }
    const clear = chips.length > 1 ? [clearAllButton(messages.clear_all)] : [];
    // The focus stays on Add filter, or on the chip of the same filter, as they are drawn again.
    const active = document.activeElement as HTMLElement | null;
    const focused = active === this.addFilter ? this.addFilter : active?.matches(".masu-chip-text") ? (active.dataset.key ?? null) : null;
    this.chipsEl.replaceChildren(...groups, ...chips, ...(this.addFilter ? [this.addFilter] : []), ...clear);
    this.chipsEl.classList.toggle("masu-filter-bar", bar);
    this.chipsEl.hidden = !bar && groups.length + chips.length === 0;
    if (focused === null) return;
    const again =
      typeof focused === "string" ? [...this.chipsEl.querySelectorAll<HTMLElement>(".masu-chip-text")].find((el) => el.dataset.key === focused) : focused;
    again?.focus({ preventScroll: true });
  }

  /** A column of the grid, shown or hidden, as a column's config (for its label and type). */
  catalogColumn(key: string): ColumnConfig | null {
    const shown = this.grid.columns.find((column) => column.key === key);
    if (shown) return shown;
    const entry = this.grid.config.catalog?.find((column) => column.key === key);
    if (!entry) return null;
    return {
      key: entry.key,
      label: entry.label,
      type: entry.type,
      width: entry.width,
      minWidth: 48,
      align: "start",
      sortable: true,
      filterable: entry.filterable,
      editable: false,
      html: false,
      pinned: null,
    };
  }

  /** Groups the rows by a column, or stops (Masu.Group). */
  private groupBy(key: string, on: boolean): void {
    const groups = (this.grid.query.groups ?? []).filter((k) => k !== key);
    this.grid.setQuery({ ...this.grid.query, groups: on ? [...groups, key] : groups });
  }

  onChipClick(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    if (this.addFilter && this.addFilter.contains(target)) {
      this.grid.toolbar.togglePanel("filters");
      return;
    }
    const remove = target.closest<HTMLElement>(".masu-chip-remove");
    if (remove?.dataset.group) {
      this.groupBy(remove.dataset.group, false);
      return;
    }
    if (remove) {
      this.grid.setQuery({ ...this.grid.query, filters: replaceFilter(this.grid.query.filters, remove.dataset.key!, null) });
      return;
    }
    if (target.closest(".masu-chips-clear")) {
      this.grid.setQuery({ ...this.grid.query, filters: [] });
      return;
    }
    const text = target.closest<HTMLElement>(".masu-chip-text");
    if (text?.dataset.col) this.openMenu(Number(text.dataset.col), { chip: text.dataset.key ?? null });
  }

  /**
   * Whether a column has a header menu: it filters there (`header_filters`),
   * or has the app's items; with the filter bar, or it sorts.
   */
  hasHeaderMenu(col: number): boolean {
    const column = this.grid.columns[col];
    if (column === undefined) return false;
    return (
      (column.filterable && this.grid.config.headerFilters !== false) ||
      (column.headerActions?.length ?? 0) > 0 ||
      (this.filterBar() && column.sortable)
    );
  }

  /**
   * Opens the header menu of a column (its sorts, its filter, and the app's
   * items), under its header; or, from the filter bar, the column's filter
   * alone, under Add filter or its chip.
   */
  openMenu(col: number, from: MenuFrom = null): void {
    const column = this.grid.columns[col];
    if (!column || !(from ? column.filterable : this.hasHeaderMenu(col))) return;
    this.closeMenu(false);
    this.grid.actions.closeCellMenu(false);
    const header = this.grid.headerRow.children[col] as HTMLElement;
    const anchor = from ? () => this.barAnchor(from) : header;
    if (!from) this.grid.ensureVisible({ row: this.grid.active.row, col });
    const menu = new FilterMenu(
      {
        root: this.grid.uiEl,
        column,
        current: this.grid.query.filters.find((filter) => filter.key === column.key),
        zoned: column.type === "datetime" ? this.zonedValues(col) : undefined,
        messages: this.grid.messages(),
        format: (value) => this.grid.formatters[col](value as CellValue),
        fetchValues: (search, done) => {
          this.grid.transport.push("masu:values", { key: column.key, search }, (reply) => {
            done((reply.values as [unknown, number][]) ?? []);
          });
        },
        apply: (filter) => {
          this.closeMenu(true);
          this.grid.setQuery({ ...this.grid.query, filters: replaceFilter(this.grid.query.filters, column.key, filter) });
        },
        close: () => this.closeMenu(true),
        filters: from !== null || this.grid.config.headerFilters !== false,
        group:
          !from && this.grid.config.groupable && column.sortable
            ? (on) => {
                this.closeMenu(true);
                this.groupBy(column.key, on);
              }
            : undefined,
        grouped: (this.grid.query.groups ?? []).includes(column.key),
        actions: from
          ? []
          : (column.headerActions ?? []).map((action) => ({
              label: action.label,
              run: () => this.grid.actions.runAction("header", action, col, -1, null),
            })),
        sort:
          !from && column.sortable
            ? {
                dir: this.grid.query.sorts.find((sort) => sort.key === column.key)?.dir ?? null,
                set: (dir) => this.grid.setSort(col, dir),
              }
            : undefined,
      },
      anchor,
    );
    this.menu = { col, menu, from };
    if (!from) header.querySelector(".masu-filter-button")?.setAttribute("aria-expanded", "true");
  }

  /** Where a menu opened from the filter bar goes: under its chip, else under Add filter. */
  private barAnchor(from: { chip: string | null }): HTMLElement {
    const chip =
      from.chip === null ? null : [...this.chipsEl.querySelectorAll<HTMLElement>(".masu-chip-text")].find((el) => el.dataset.key === from.chip);
    return chip ?? this.addFilter ?? this.chipsEl;
  }

  /**
   * Whether a column's datetimes have a zone, from the first one of the
   * rows the browser has around the screen: a `NaiveDateTime` comes
   * without one. True when it has none of them yet.
   */
  private zonedValues(col: number): boolean {
    const first = this.grid.firstWholeRow();
    for (let index = first, last = Math.min(this.grid.span(), first + 200); index < last; index++) {
      const value = this.grid.cache.get(index)?.[col + 1];
      if (value !== null && value !== undefined) return zoned(value);
    }
    return true;
  }

  closeMenu(focus: boolean): void {
    if (!this.menu) return;
    const { col, menu, from } = this.menu;
    this.menu = null;
    menu.destroy();
    this.grid.headerRow.children[col]?.querySelector(".masu-filter-button")?.setAttribute("aria-expanded", "false");
    // Opened from the filter bar: the focus goes back to it.
    if (focus && from) {
      const anchor = this.barAnchor(from);
      if (anchor !== this.chipsEl) anchor.focus({ preventScroll: true });
      return;
    }
    if (focus) {
      this.grid.active = { row: -1, col };
      this.grid.gridEl.focus({ preventScroll: true });
      this.grid.render();
    }
  }
}
