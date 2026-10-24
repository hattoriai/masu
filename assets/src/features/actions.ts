// The menu of a cell, a row's menu, and the items of the app's own
// (Masu.Action): what they run, the panels the server renders for them, and
// the tasks they start.

import { ActionMenu, type MenuItem } from "../actions";
import { clip, setStyle } from "../dom";
import { allows, replaceFilter } from "../filters";
import { drop, floats, follow, lift, place as placeAt } from "../float";
import { contains, rect, type Cell, type Rect } from "../geometry";
import { MAX_COPY_ROWS } from "../limits";
import { isDraft, isGroup, rawValue } from "../rows";
import type { RowElement } from "../records";
import type { ActionItem, CellValue, ColumnType, FilterSpec, Progress, Reply, Row, RowsAction } from "../types";
import type { Grid } from "../grid";

/** How long the line of an action's result stays. */
const TASK_SHOWN = 6000;

/** The types whose values have an order: a cell's menu filters by its value as a bound. */
const ORDERED: ColumnType[] = ["integer", "number", "decimal", "date", "datetime", "time"];

export class Actions {
  /** The menu of a cell: the grid's items and the app's (Masu.Action). */
  cellMenu: ActionMenu | null = null;
  /** Where the panel of an item (Masu.Action), which the server renders, goes: a header (row -1) or a cell. */
  private actionAnchor: { col: number; row: number; focus: boolean } | null = null;
  private wiredPanels = new WeakSet<HTMLElement>();
  /** Places the server's panel again as the page scrolls, while it is open. */
  private panelFollow: (() => void) | null = null;
  /** Lines above the grid: an action that runs, how far it is, how it went. */
  private tasksEl: HTMLElement | null = null;

  constructor(private readonly grid: Grid) {}

  onContextMenu(event: MouseEvent): void {
    if (this.grid.details.inDetail(event.target) || this.grid.editing.editor) return;
    // Opened by its key already, which the browser follows with this event.
    if (this.cellMenu || this.grid.filters.menu) {
      event.preventDefault();
      return;
    }
    const target = event.target as HTMLElement;
    const header = target.closest<HTMLElement>(".masu-hcell");
    if (header && header.parentElement === this.grid.headerRow) {
      // A header's own menu, when the app has items for its headers.
      const col = Number(header.dataset.col);
      if ((this.grid.columns[col]?.headerActions?.length ?? 0) > 0) {
        event.preventDefault();
        this.grid.filters.openMenu(col);
      }
      return;
    }
    // The cell of a row's actions: their menu.
    const more = target.closest<HTMLElement>(".masu-row-actions");
    const moreRow = more?.parentElement as RowElement | null;
    if (more && moreRow?.masuIndex !== undefined) {
      event.preventDefault();
      this.openRowMenu(moreRow.masuIndex, more);
      return;
    }
    // From the keyboard, the event is on the grid: the active cell's menu.
    const cell = target === this.grid.gridEl ? (this.grid.active.row >= 0 ? this.grid.active : null) : this.grid.cellAt(target);
    if (!cell) return;
    const at = target === this.grid.gridEl ? null : { x: event.clientX, y: event.clientY };
    if (this.openCellMenu(cell, at)) event.preventDefault();
  }

  /**
   * Opens the menu of a cell, at a point (a click's) or under the cell.
   * Returns whether it has a menu: the grid's items (`cell_menu`) or the
   * app's, for a row of data (not a group's, nor a new row).
   */
  openCellMenu(cell: Cell, at: { x: number; y: number } | null): boolean {
    const data = this.grid.dataAt(cell.row);
    if (!data || isGroup(data) || isDraft(data)) return false;
    const items = this.cellItems(cell, data);
    if (items.length === 0) return false;

    this.grid.filters.closeMenu(false);
    this.closeCellMenu(false);
    this.closeActionPanel(false);
    if (!at) {
      this.grid.ensureVisible(cell);
      this.grid.render();
      const box = this.cellElement(cell)?.getBoundingClientRect();
      at = box ? { x: box.left, y: box.bottom } : { x: 0, y: 0 };
    }
    const column = this.grid.columns[cell.col];
    this.cellMenu = new ActionMenu(
      { root: this.grid.uiEl, label: this.grid.message("cell_menu", { label: column.label }), close: (focus) => this.closeCellMenu(focus) },
      items,
      at,
    );
    return true;
  }

  closeCellMenu(focus: boolean): void {
    if (!this.cellMenu) return;
    this.cellMenu.destroy();
    this.cellMenu = null;
    if (focus) this.grid.gridEl.focus({ preventScroll: true });
  }

  cellElement(cell: Cell): HTMLElement | null {
    if (cell.row < 0) return (this.grid.headerRow.children[cell.col] as HTMLElement | undefined) ?? null;
    return (this.grid.rows.get(cell.row)?.children[cell.col] as HTMLElement | undefined) ?? null;
  }

  /** The items of a cell's menu: copy, filter, sort (`cell_menu`), then the app's. */
  private cellItems(cell: Cell, data: Row): MenuItem[] {
    const column = this.grid.columns[cell.col];
    const builtIn = this.grid.config.cellMenu ?? [];
    const range = this.grid.highlight();
    const inRange = range && contains(range, cell.row, cell.col) ? range : null;
    const items: MenuItem[] = [];
    const group = (more: MenuItem[]) => {
      if (more.length > 0) more[0].separated = true;
      items.push(...more);
    };

    if (builtIn.includes("copy")) {
      const copied = inRange ?? rect(cell, cell);
      group([
        { name: "copy", label: this.grid.message("copy", {}), run: () => this.grid.clipboard.copyRange(copied, false) },
        { name: "copy-headers", label: this.grid.message("copy_with_headers", {}), run: () => this.grid.clipboard.copyRange(copied, true) },
      ]);
    }

    // A cell of HEEx has its value only when it edits.
    const sent = data[cell.col + 1];
    const known = column.many || !column.html || Array.isArray(sent);
    if (builtIn.includes("filter") && column.filterable && known) {
      // Of many values: by none or some, not by the cell's values.
      const value = column.many ? null : rawValue(sent);
      const filter = (spec: FilterSpec) => () =>
        this.grid.setQuery({ ...this.grid.query, filters: replaceFilter(this.grid.query.filters, column.key, spec) });
      // Only the filters the column's source runs.
      const more: MenuItem[] = [];
      if (value !== null) {
        const shown = clip(column.type === "boolean" ? this.grid.message(value ? "yes" : "no", {}) : this.grid.formatters[cell.col](value));
        const only: FilterSpec | null =
          column.type === "enum" && allows(column, "in")
            ? { key: column.key, op: "in", value: [value] }
            : allows(column, "eq")
              ? { key: column.key, op: "eq", value }
              : null;
        if (only) more.push({ name: "filter-value", label: this.grid.message("filter_value", { label: shown }), run: filter(only) });
        if (allows(column, "neq")) {
          more.push({
            name: "exclude-value",
            label: this.grid.message("exclude_value", { label: shown }),
            run: filter({ key: column.key, op: "neq", value }),
          });
        }
        // The value as a bound, for the columns that have an order, and
        // for text when the column's filters name the comparisons (a SQL
        // client's, which compares text in its order); a text's value as
        // a part of others.
        const text = column.type === "text";
        if (ORDERED.includes(column.type) || (text && column.filters)) {
          const timely = column.type === "date" || column.type === "datetime" || column.type === "time";
          for (const op of ["gt", "lt", "gte", "lte"] as const) {
            if (!allows(column, op)) continue;
            const words = this.grid.message(`filter_${op}${timely ? "_time" : ""}`, { label: shown });
            more.push({ name: `filter-${op}`, label: words, run: filter({ key: column.key, op, value }) });
          }
        }
        if (text && allows(column, "contains")) {
          more.push({
            name: "filter-contains",
            label: this.grid.message("filter_contains", { label: shown }),
            run: filter({ key: column.key, op: "contains", value }),
          });
        }
      }
      if (allows(column, "is_nil")) {
        const words = this.grid.message(column.many ? "filter_none" : "filter_empty", {});
        more.push({ name: "filter-empty", label: words, run: filter({ key: column.key, op: "is_nil" }) });
      }
      if (allows(column, "not_nil")) {
        const words = this.grid.message(column.many ? "filter_some" : "filter_not_empty", {});
        more.push({ name: "filter-not-empty", label: words, run: filter({ key: column.key, op: "not_nil" }) });
      }
      group(more);
    }

    if (builtIn.includes("sort") && column.sortable) {
      const sort = (dir: "asc" | "desc") => () => this.grid.setQuery({ ...this.grid.query, sorts: [{ key: column.key, dir }] });
      group([
        { name: "sort-asc", label: this.grid.message("sort_asc", {}), run: sort("asc") },
        { name: "sort-desc", label: this.grid.message("sort_desc", {}), run: sort("desc") },
      ]);
    }

    group(
      (column.cellActions ?? []).map((action) => ({
        label: action.label,
        run: () => this.runAction("cell", action, cell.col, cell.row, inRange),
      })),
    );
    group(this.rowItems(data));
    if (this.grid.config.history) {
      group([
        { name: "history", label: this.grid.message("history", {}), run: () => this.grid.history.openHistory(cell, true) },
        { name: "row-history", label: this.grid.message("row_history", {}), run: () => this.grid.history.openHistory(cell, false) },
      ]);
    }
    return items;
  }

  /** The items of a row's actions (Masu.Action): those it shows, links, disabled ones too. */
  private rowItems(data: Row): MenuItem[] {
    const actions = new Map((this.grid.config.rowActions ?? []).map((action) => [action.id, action]));
    return this.grid.rowActionsOf(data).flatMap(([id, disabled, href]) => {
      const action = actions.get(id);
      if (!action) return [];
      const item: MenuItem = {
        label: action.label,
        disabled,
        danger: action.danger,
        run: () => this.runRowAction(action, data),
      };
      if (action.link && href) {
        item.href = href;
        item.link = action.link;
      }
      return [item];
    });
  }

  /** Opens the menu of a row's actions, under its button. */
  openRowMenu(index: number, button: HTMLElement): void {
    const data = this.grid.dataAt(index);
    if (!data || isGroup(data) || isDraft(data)) return;
    const items = this.rowItems(data);
    if (items.length === 0) return;
    this.grid.filters.closeMenu(false);
    this.closeCellMenu(false);
    this.closeActionPanel(false);
    this.grid.active = { row: index, col: Math.max(0, this.grid.active.col) };
    this.grid.anchor = null;
    this.grid.render();
    const box = button.getBoundingClientRect();
    this.cellMenu = new ActionMenu(
      { root: this.grid.uiEl, label: this.grid.message("row_actions", {}), close: (focus) => this.closeCellMenu(focus) },
      items,
      { x: box.left, y: box.bottom },
    );
  }

  /** Runs a row action on the server, after its question. */
  private runRowAction(action: RowsAction, data: Row): void {
    const run = () =>
      this.grid.transport.push("masu:action", { kind: "row", action: action.id, label: action.label, id: data[0] }, (reply) =>
        this.actionReply(action.label, reply),
      );
    if (action.confirm) this.grid.deleting.confirm(action.confirm, action.label, run, action.danger);
    else run();
  }

  /** Runs an action on the rows selected, after its question ("Delete {count} orders?"). */
  runSelectionAction(action: RowsAction): void {
    const run = () => {
      this.grid.rowSelection.selectionBar?.querySelectorAll("button").forEach((button) => (button.disabled = true));
      this.grid.transport.push("masu:action", { kind: "selection", action: action.id, label: action.label }, (reply) => {
        this.grid.rowSelection.selectionBar?.querySelectorAll("button").forEach((button) => (button.disabled = false));
        this.actionReply(action.label, reply);
      });
    };
    if (action.confirm) this.grid.deleting.confirm(this.grid.fill(action.confirm, { count: this.grid.rowSelection.chosen.count }), action.label, run, action.danger);
    else run();
  }

  /** What an action's answer says: done (with its message), failed, or going on until Masu.reply/2. */
  private actionReply(label: string, reply: Record<string, unknown>): void {
    if (typeof reply.async === "string") {
      this.grid.later.set(reply.async, { kind: "action", label });
      this.showTask(reply.async, this.grid.message("action_running", { label }), "running");
    } else if (typeof reply.failed === "string") {
      this.showTask(null, reply.failed, "error");
    } else if (reply.error) {
      this.showTask(null, this.grid.message("action_failed", {}), "error");
    } else {
      const message = typeof reply.message === "string" ? reply.message : this.grid.message("action_done", { label });
      this.showTask(null, message, "done");
    }
  }

  /**
   * A line above the grid: an action that runs (until its reply), or how
   * one went (for a few seconds); a screen reader hears it.
   */
  private showTask(token: string | null, text: string, state: "running" | "done" | "error"): void {
    if (!this.tasksEl) {
      this.tasksEl = document.createElement("div");
      this.tasksEl.className = "masu-tasks";
      this.grid.uiEl.appendChild(this.tasksEl);
    }
    const existing = token ? this.tasksEl.querySelector<HTMLElement>(`[data-token="${CSS.escape(token)}"]`) : null;
    const line = existing ?? document.createElement("div");
    line.className = "masu-task";
    line.dataset.state = state;
    if (token) line.dataset.token = token;
    line.textContent = text;
    if (!existing) this.tasksEl.appendChild(line);
    this.grid.announce(text);
    if (state !== "running") {
      delete line.dataset.token;
      setTimeout(() => line.remove(), TASK_SHOWN);
    }
  }

  /** A write or an action that went on later replied (Masu.reply/2). */
  receiveReply(reply: Reply): void {
    const later = this.grid.later.get(reply.token);
    if (!later) return;
    this.grid.later.delete(reply.token);

    if (later.kind === "action") {
      const text = reply.message ?? (reply.ok ? this.grid.message("action_done", { label: later.label }) : this.grid.message("action_failed", {}));
      this.showTask(reply.token, text, reply.ok ? "done" : "error");
    } else if (later.kind === "edits") {
      this.grid.editing.takeEditReply(later.edits, reply.errors as [unknown, string, string, CellValue?][], later.mode);
      if (reply.ok && reply.message) this.grid.announce(reply.message);
    } else {
      const errors = reply.errors as [unknown, string][];
      if (!reply.ok) this.grid.announce(errors[0]?.[1] ?? reply.message ?? this.grid.message("action_failed", {}));
      else this.grid.announce(reply.message ?? (later.count === 1 ? this.grid.message("deleted_one", {}) : this.grid.message("deleted", { count: later.count })));
    }
  }

  /** How far an action that went on later is (Masu.progress/3). */
  receiveProgress(progress: Progress): void {
    const later = this.grid.later.get(progress.token);
    if (later?.kind !== "action") return;
    this.showTask(progress.token, this.grid.message("action_progress", { label: later.label, done: progress.done, total: progress.total }), "running");
  }

  /**
   * Runs an item of the app's (Masu.Action) on a header (row -1) or a
   * cell: its JS command here, and on the server its function, its event
   * or its panel. The server reads the row and the value itself.
   */
  runAction(kind: "header" | "cell", action: ActionItem, col: number, row: number, range: Rect | null): void {
    const column = this.grid.columns[col];
    if (!column) return;
    const data = row >= 0 ? this.grid.dataAt(row) : undefined;
    if (kind === "cell" && !data) return;

    this.rangeIds(range, (ids) => {
      const keys = range ? this.grid.columns.slice(range.left, range.right + 1).map((c) => c.key) : null;
      if (action.js) {
        const sent = data?.[col + 1];
        const detail: Record<string, unknown> = { grid: this.grid.id, kind, action: action.label, column: column.key };
        if (data) {
          detail.id = data[0];
          detail.value = !column.html || Array.isArray(sent) ? rawValue(sent) : null;
        }
        if (ids && keys) detail.range = { ids, columns: keys };
        this.grid.el.dispatchEvent(new CustomEvent("masu:action", { bubbles: true, detail }));
        this.grid.transport.exec?.(action.js);
      }
      if (!action.server && !action.panel) return;

      const payload: Record<string, unknown> = { kind, action: action.id, label: action.label, key: column.key };
      if (data) payload.id = data[0];
      if (ids && keys) payload.range = { ids, keys };
      this.grid.transport.push("masu:action", payload, (reply) => {
        if (reply.panel) {
          this.actionAnchor = { col, row, focus: true };
          this.placeActionPanel();
        } else if (reply.error) {
          this.grid.announce(this.grid.message("action_failed", {}));
        }
      });
    });
  }

  /** The ids of the rows of a range of several cells (as many as a copy takes), or null. */
  private rangeIds(range: Rect | null, then: (ids: unknown[] | null) => void): void {
    if (!range || (range.top === range.bottom && range.left === range.right)) {
      then(null);
      return;
    }
    const last = Math.min(range.bottom, range.top + MAX_COPY_ROWS - 1);
    this.grid.load(range.top, last, () => {
      const ids: unknown[] = [];
      for (let index = range.top; index <= last; index++) {
        const data = this.grid.dataAt(index);
        if (data && !isGroup(data) && !isDraft(data)) ids.push(data[0]);
      }
      then(ids);
    });
  }

  /** The panel of an item that the server rendered, if open. */
  actionPanel(): HTMLElement | null {
    const panel = this.grid.el.querySelector<HTMLElement>(":scope > .masu-panels > .masu-action-panel");
    return panel && !panel.hidden ? panel : null;
  }

  /**
   * Places the server's panel under its header or cell, inside the
   * grid's element: again after each render, which takes its style away.
   */
  placeActionPanel(): void {
    const panel = this.actionPanel();
    if (!panel) return this.unfollowPanel();
    const col = this.grid.columns.findIndex((column) => column.key === panel.dataset.key);
    const anchor = this.actionAnchor ?? { col: Math.max(col, 0), row: -1, focus: false };
    const target = this.cellElement({ row: anchor.row, col: anchor.col }) ?? this.cellElement({ row: -1, col: anchor.col });
    const box = (target ?? this.grid.gridEl).getBoundingClientRect();
    if (floats(panel)) {
      lift(panel);
      placeAt(panel, { left: box.left, below: box.bottom + 4, above: box.top - 4 }, (name, value) =>
        setStyle(panel, name, value),
      );
      this.panelFollow ??= follow(() => this.placeActionPanel());
    } else {
      const root = this.grid.el.getBoundingClientRect();
      const left = Math.max(0, Math.min(box.left - root.left, root.width - panel.offsetWidth));
      setStyle(panel, "top", `${box.bottom - root.top + 4}px`);
      setStyle(panel, "inset-inline-start", `${left}px`);
    }

    if (!this.wiredPanels.has(panel)) {
      this.wiredPanels.add(panel);
      panel.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          this.closeActionPanel(true);
        }
      });
    }
    if (anchor.focus) {
      anchor.focus = false;
      const first = panel.querySelector<HTMLElement>('a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])');
      (first ?? panel).focus();
    }
  }

  closeActionPanel(focus: boolean): void {
    const panel = this.actionPanel();
    if (!panel) return;
    drop(panel);
    panel.hidden = true;
    this.unfollowPanel();
    this.actionAnchor = null;
    this.grid.transport.push("masu:action_panel", { open: false });
    if (focus) this.grid.gridEl.focus({ preventScroll: true });
  }

  unfollowPanel(): void {
    this.panelFollow?.();
    this.panelFollow = null;
  }
}
