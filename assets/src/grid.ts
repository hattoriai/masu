// The grid in the browser. The server renders its structure and first
// rows (Masu.Grid); the grid takes them over and from then on draws only
// the rows on the screen, a few more on each side, reusing their
// elements as the person scrolls. The rows it lacks it asks the server
// for, a block at a time (BlockCache), once the scrolling pauses.
//
// Focus stays on the grid element; the active cell is its
// aria-activedescendant, so that a screen reader follows it while the
// rows come and go.

import { BlockCache } from "./blocks";
import { describe, replaceFilter } from "./filters";
import { fromTSV, inputText, placePaste, sendValue, shownValue } from "./parse";
import { FilterMenu } from "./menu";
import { copyText, formatter, type Formatter } from "./format";
import { contains, move, rect, visibleRows, type Cell, type Rect } from "./geometry";
import { nextSorts } from "./sorting";
import { toTSV } from "./tsv";
import type { BlockReply, CellValue, ColumnConfig, Config, QuerySpec, Row, Transport } from "./types";

const OVERSCAN = 8;
const PREFETCH = 60;
const REQUEST_DELAY = 40;
const SEARCH_DELAY = 250;
const MAX_COPY_ROWS = 10_000;
const MAX_AUTO_WIDTH = 640;
const FLASH = 1600;

interface RowElement extends HTMLDivElement {
  masuIndex?: number;
  masuRow?: Row | null;
}

export class Grid {
  readonly el: HTMLElement;
  readonly id: string;
  private transport: Transport;
  private config: Config;
  private columns: ColumnConfig[];
  private widths: number[];
  private formatters: Formatter[] = [];
  private total: number;
  private revision: number;
  private query: QuerySpec;
  private cache = new BlockCache();
  /** The rows of the revision before, shown until the new ones come. */
  private stale: BlockCache | null = null;
  /** The rows on the screen are old: ask for them at once, not after a pause. */
  private urgent = false;

  private gridEl: HTMLElement;
  private head: HTMLElement;
  private headerRow: HTMLElement;
  private body: HTMLElement;
  private emptyEl: HTMLElement | null;
  private statusEl: HTMLElement | null;
  private searchEl: HTMLInputElement | null;
  private chipsEl: HTMLElement;
  private menu: { col: number; menu: FilterMenu } | null = null;

  private rows = new Map<number, RowElement>();
  private pool: RowElement[] = [];
  private active: Cell = { row: 0, col: 0 };
  private anchor: Cell | null = null;
  private dragging = false;
  private frame: number | null = null;
  private queries = 0;
  /** The cell being edited. */
  private editor: Editor | null = null;
  /** The errors of cells the server did not save, by cellKey(). */
  private errors = new Map<string, string>();
  /** The cells being saved, by cellKey(). */
  private saving = new Set<string>();
  private undoStack: Edit[][] = [];
  private redoStack: Edit[][] = [];

  /** The rows that changed (Masu.Live), each until its flash ends. */
  private flash = new Map<string, number>();
  private requestTimer: ReturnType<typeof setTimeout> | null = null;
  private searchTimer: ReturnType<typeof setTimeout> | null = null;
  private observer: ResizeObserver | null = null;
  private cleanups: (() => void)[] = [];

  constructor(el: HTMLElement, transport: Transport) {
    this.el = el;
    this.id = el.id;
    this.transport = transport;
    this.config = readConfig(el);
    this.columns = this.config.columns;
    this.widths = this.columns.map((column) => column.width);
    this.total = this.config.total;
    this.revision = this.config.revision;
    this.query = this.config.query;

    this.gridEl = el.querySelector<HTMLElement>(".masu-grid")!;
    this.head = this.gridEl.querySelector<HTMLElement>(".masu-head")!;
    this.headerRow = this.head.querySelector<HTMLElement>(".masu-header")!;
    this.body = this.gridEl.querySelector<HTMLElement>(".masu-body")!;
    this.emptyEl = this.gridEl.querySelector<HTMLElement>(".masu-empty");
    this.statusEl = el.querySelector<HTMLElement>(".masu-status");
    this.searchEl = el.querySelector<HTMLInputElement>(".masu-search");

    // The chips of the filters, above the grid.
    this.chipsEl = document.createElement("div");
    this.chipsEl.className = "masu-chips";
    this.gridEl.before(this.chipsEl);

    this.makeFormatters();
    if (this.config.initial) this.cache.store(this.config.initial.from, this.config.initial.rows);

    this.renderHeader();
    this.applyWidths();
    this.body.replaceChildren();
    this.listen();
    this.render();
  }

  /** The server rendered the grid again: new rows, columns or options. */
  update(): void {
    const config = readConfig(this.el);
    const columnsChanged = JSON.stringify(config.columns) !== JSON.stringify(this.config.columns);
    this.config = config;

    if (columnsChanged) {
      const widths = new Map(this.columns.map((column, i) => [column.key, this.widths[i]]));
      this.columns = config.columns;
      this.widths = this.columns.map((column) => widths.get(column.key) ?? column.width);
      this.makeFormatters();
      this.renderHeader();
      this.applyWidths();
      this.clearRows();
      this.pool = [];
    }

    if (config.revision > this.revision) {
      // New rows from the server (a live change, or new rows of the
      // LiveView): the person keeps their place; the rows that changed
      // flash as they are drawn.
      const now = performance.now();
      for (const [id, until] of this.flash) if (until < now) this.flash.delete(id);
      for (const id of config.changed ?? []) this.flash.set(String(id), now + FLASH);
      this.revision = config.revision;
      this.total = config.total;
      this.query = config.query;
      // The rows of the older revision stay on the screen until the new
      // ones come, so that the grid does not blink as its rows change.
      this.stale = this.cache;
      this.cache = new BlockCache(this.stale.size, this.stale.maxBlocks);
      if (config.initial) this.cache.store(config.initial.from, config.initial.rows);
      this.renderHeader();
      this.urgent = true;
    }

    this.render();
  }

  destroy(): void {
    this.closeMenu(false);
    this.editor?.input.remove();
    this.editor = null;
    for (const cleanup of this.cleanups) cleanup();
    this.cleanups = [];
    this.observer?.disconnect();
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    if (this.requestTimer) clearTimeout(this.requestTimer);
    if (this.searchTimer) clearTimeout(this.searchTimer);
  }

  // The query: a new order, filters or search, applied by the server.

  setQuery(query: QuerySpec): void {
    // The new query shows at once, so that a second click builds on the
    // first; only the answer to the last query asked for is applied.
    const previous = this.query;
    const sent = ++this.queries;
    this.query = query;
    this.renderHeader();
    this.el.classList.add("masu-busy");

    this.transport.push("masu:query", query, (reply) => {
      if (sent !== this.queries) return;
      this.el.classList.remove("masu-busy");
      const answer = reply as unknown as BlockReply;
      if (answer.error) {
        this.query = previous;
        this.renderHeader();
        this.announce(answer.error);
        return;
      }
      this.revision = answer.revision;
      this.total = answer.total;
      this.query = answer.query ?? query;
      this.cache.clear();
      this.stale = null;
      this.cache.store(answer.from, answer.rows);
      this.gridEl.scrollTop = 0;
      this.active = { row: Math.min(Math.max(this.active.row, -1), this.total - 1), col: this.active.col };
      this.anchor = null;
      this.renderHeader();
      this.clearRows();
      this.render();
      this.announceCount();
    });
  }

  // Rendering.

  private schedule(): void {
    if (this.frame !== null) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.render();
    });
  }

  private render(): void {
    const rh = this.config.rowHeight;
    this.body.style.height = `${this.total * rh}px`;
    this.gridEl.setAttribute("aria-rowcount", String(this.total + 1));
    this.gridEl.setAttribute("aria-colcount", String(this.columns.length));
    if (this.emptyEl) this.emptyEl.hidden = this.total > 0;

    const headHeight = this.head.offsetHeight;
    const { first, last } = visibleRows(
      this.gridEl.scrollTop,
      this.gridEl.clientHeight - headHeight,
      rh,
      this.total,
      OVERSCAN,
    );

    for (const [index, rowEl] of this.rows) {
      if (index < first || index > last) {
        rowEl.remove();
        rowEl.masuIndex = undefined;
        rowEl.masuRow = undefined;
        this.rows.delete(index);
        this.pool.push(rowEl);
      }
    }

    const selection = this.highlight();
    for (let index = first; index <= last; index++) {
      let rowEl = this.rows.get(index);
      if (!rowEl) {
        rowEl = this.pool.pop() ?? this.makeRow();
        rowEl.masuIndex = index;
        rowEl.style.transform = `translateY(${index * rh}px)`;
        rowEl.setAttribute("aria-rowindex", String(index + 2));
        this.body.appendChild(rowEl);
        this.rows.set(index, rowEl);
      }
      this.fillRow(rowEl, index, this.cache.get(index) ?? this.stale?.get(index) ?? null);
      this.markRow(rowEl, index, selection);
    }

    this.markHeader(selection);
    this.updateActiveDescendant();
    this.cache.evict(this.cache.blockOf(first));
    this.planRequests(first, last);
  }

  private clearRows(): void {
    for (const rowEl of this.rows.values()) {
      rowEl.remove();
      rowEl.masuIndex = undefined;
      rowEl.masuRow = undefined;
      this.pool.push(rowEl);
    }
    this.rows.clear();
  }

  private makeRow(): RowElement {
    const rowEl = document.createElement("div") as RowElement;
    rowEl.className = "masu-row";
    rowEl.setAttribute("role", "row");
    this.columns.forEach((column, col) => rowEl.appendChild(this.makeCell(column, col)));
    return rowEl;
  }

  private makeCell(column: ColumnConfig, col: number): HTMLDivElement {
    const cell = document.createElement("div");
    cell.className = `masu-cell masu-align-${column.align} masu-type-${column.type}`;
    cell.setAttribute("role", "gridcell");
    cell.setAttribute("aria-colindex", String(col + 1));
    return cell;
  }

  private fillRow(rowEl: RowElement, index: number, row: Row | null): void {
    if (rowEl.masuRow === row && rowEl.masuIndex === index && rowEl.dataset.index === String(index)) return;
    rowEl.masuRow = row;
    rowEl.dataset.index = String(index);
    rowEl.classList.toggle("masu-loading", row === null);
    rowEl.setAttribute("aria-busy", row === null ? "true" : "false");

    const flashing = row !== null && this.flashing(row[0]);
    rowEl.classList.toggle("masu-changed", flashing);

    const cells = rowEl.children;
    this.columns.forEach((column, col) => {
      const cell = cells[col] as HTMLElement;
      cell.id = `${this.id}-r${index}-c${col}`;
      if (row === null) {
        cell.textContent = "";
      } else if (column.html) {
        const value = row[col + 1] as unknown;
        cell.innerHTML = (Array.isArray(value) ? (value[0] as string) : (value as string | null)) ?? "";
      } else {
        const value = row[col + 1] as CellValue;
        cell.textContent = this.formatters[col](value);
        cell.classList.toggle("masu-null", value === null);
      }

      const key = row === null ? "" : cellKey(row[0], column.key);
      const error = row === null ? undefined : this.errors.get(key);
      cell.classList.toggle("masu-invalid", error !== undefined);
      cell.classList.toggle("masu-saving", row !== null && this.saving.has(key));
      const locked = row !== null && column.editable === true && this.locked(row, col);
      cell.classList.toggle("masu-editable", column.editable === true && !locked);
      cell.classList.toggle("masu-locked", locked);
      if (column.editable) cell.setAttribute("aria-readonly", locked ? "true" : "false");
      if (error !== undefined) {
        cell.title = error;
        cell.setAttribute("aria-invalid", "true");
      } else {
        cell.removeAttribute("title");
        cell.removeAttribute("aria-invalid");
      }
    });
  }

  private flashing(id: unknown): boolean {
    const until = this.flash.get(String(id));
    if (until === undefined) return false;
    if (performance.now() <= until) return true;
    this.flash.delete(String(id));
    return false;
  }

  private markRow(rowEl: RowElement, index: number, selection: Rect | null): void {
    const cells = rowEl.children;
    const inRows = selection !== null && index >= selection.top && index <= selection.bottom;
    rowEl.classList.toggle("masu-row-selected", inRows);
    for (let col = 0; col < cells.length; col++) {
      const cell = cells[col] as HTMLElement;
      const selected = selection !== null && contains(selection, index, col);
      cell.classList.toggle("masu-selected", selected);
      cell.setAttribute("aria-selected", selected ? "true" : "false");
      cell.classList.toggle("masu-active", this.active.row === index && this.active.col === col);
    }
  }

  private markHeader(selection: Rect | null): void {
    const cells = this.headerRow.children;
    for (let col = 0; col < cells.length; col++) {
      const cell = cells[col] as HTMLElement;
      cell.classList.toggle("masu-active", this.active.row === -1 && this.active.col === col);
      cell.classList.toggle("masu-col-selected", selection !== null && col >= selection.left && col <= selection.right);
    }
  }

  private updateActiveDescendant(): void {
    const id =
      this.active.row === -1 ? `${this.id}-h${this.active.col}` : `${this.id}-r${this.active.row}-c${this.active.col}`;
    if (document.getElementById(id) && this.total + 1 > 0) this.gridEl.setAttribute("aria-activedescendant", id);
    else this.gridEl.removeAttribute("aria-activedescendant");
  }

  private renderHeader(): void {
    const cells = this.columns.map((column, col) => {
      const cell = document.createElement("div");
      cell.id = `${this.id}-h${col}`;
      cell.className = `masu-hcell masu-align-${column.align}${column.sortable ? " masu-sortable" : ""}`;
      cell.setAttribute("role", "columnheader");
      cell.setAttribute("aria-colindex", String(col + 1));
      cell.dataset.key = column.key;
      cell.dataset.col = String(col);

      const label = document.createElement("span");
      label.className = "masu-label";
      label.textContent = column.label;
      cell.appendChild(label);

      const position = this.query.sorts.findIndex((sort) => sort.key === column.key);
      if (column.sortable) {
        const sort = this.query.sorts[position];
        const icon = document.createElement("span");
        icon.className = "masu-sort";
        icon.setAttribute("aria-hidden", "true");
        if (sort) {
          icon.dataset.dir = sort.dir;
          if (this.query.sorts.length > 1) icon.textContent = String(position + 1);
        }
        cell.appendChild(icon);
        cell.setAttribute("aria-sort", position === 0 ? (sort.dir === "asc" ? "ascending" : "descending") : "none");
      }

      if (column.filterable) {
        const filtered = this.query.filters.some((filter) => filter.key === column.key);
        const filter = document.createElement("button");
        filter.type = "button";
        filter.tabIndex = -1;
        filter.className = "masu-filter-button";
        filter.dataset.col = String(col);
        filter.setAttribute("aria-label", this.message("filter", { label: column.label }));
        filter.setAttribute("aria-haspopup", "dialog");
        filter.setAttribute("aria-expanded", this.menu?.col === col ? "true" : "false");
        if (filtered) filter.dataset.active = "true";
        filter.innerHTML = FILTER_ICON;
        cell.appendChild(filter);
      }

      const resizer = document.createElement("span");
      resizer.className = "masu-resizer";
      resizer.setAttribute("aria-hidden", "true");
      cell.appendChild(resizer);
      return cell;
    });
    this.headerRow.replaceChildren(...cells);
    this.renderChips();
  }

  private renderChips(): void {
    const messages = this.messages();
    const chips = this.query.filters.flatMap((filter) => {
      const col = this.columns.findIndex((column) => column.key === filter.key);
      if (col < 0) return [];
      const chip = document.createElement("span");
      chip.className = "masu-chip";
      const text = document.createElement("button");
      text.type = "button";
      text.className = "masu-chip-text";
      text.dataset.col = String(col);
      text.textContent = describe(filter, this.columns[col], (value) => this.formatters[col](value as CellValue), messages);
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "masu-chip-remove";
      remove.dataset.key = filter.key;
      remove.setAttribute("aria-label", `${messages.remove_filter}: ${text.textContent}`);
      remove.textContent = "×";
      chip.append(text, remove);
      return [chip];
    });

    if (chips.length > 1) {
      const clear = document.createElement("button");
      clear.type = "button";
      clear.className = "masu-chips-clear";
      clear.textContent = messages.clear_all;
      chips.push(clear);
    }
    this.chipsEl.replaceChildren(...chips);
    this.chipsEl.hidden = chips.length === 0;
  }

  private onChipClick(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    const remove = target.closest<HTMLElement>(".masu-chip-remove");
    if (remove) {
      this.setQuery({ ...this.query, filters: replaceFilter(this.query.filters, remove.dataset.key!, null) });
      return;
    }
    if (target.closest(".masu-chips-clear")) {
      this.setQuery({ ...this.query, filters: [] });
      return;
    }
    const text = target.closest<HTMLElement>(".masu-chip-text");
    if (text) this.openMenu(Number(text.dataset.col));
  }

  /** Opens the filter menu of a column, under its header. */
  openMenu(col: number): void {
    const column = this.columns[col];
    if (!column?.filterable) return;
    this.closeMenu(false);
    const anchor = this.headerRow.children[col] as HTMLElement;
    this.ensureVisible({ row: this.active.row, col });
    const menu = new FilterMenu(
      {
        root: this.el,
        column,
        current: this.query.filters.find((filter) => filter.key === column.key),
        messages: this.messages(),
        format: (value) => this.formatters[col](value as CellValue),
        fetchValues: (search, done) => {
          this.transport.push("masu:values", { key: column.key, search }, (reply) => {
            done((reply.values as [unknown, number][]) ?? []);
          });
        },
        apply: (filter) => {
          this.closeMenu(true);
          this.setQuery({ ...this.query, filters: replaceFilter(this.query.filters, column.key, filter) });
        },
        close: () => this.closeMenu(true),
      },
      anchor,
    );
    this.menu = { col, menu };
    anchor.querySelector(".masu-filter-button")?.setAttribute("aria-expanded", "true");
  }

  private closeMenu(focus: boolean): void {
    if (!this.menu) return;
    const { col, menu } = this.menu;
    this.menu = null;
    menu.destroy();
    this.headerRow.children[col]?.querySelector(".masu-filter-button")?.setAttribute("aria-expanded", "false");
    if (focus) {
      this.active = { row: -1, col };
      this.gridEl.focus({ preventScroll: true });
      this.render();
    }
  }

  private messages(): Record<string, string> {
    return { ...DEFAULT_MESSAGES, ...this.config.messages };
  }

  private applyWidths(): void {
    this.gridEl.style.setProperty("--masu-cols", this.widths.map((width) => `${width}px`).join(" "));
    this.gridEl.style.setProperty("--masu-width", `${this.widths.reduce((a, b) => a + b, 0)}px`);
  }

  private makeFormatters(): void {
    const locale = this.config.locale ?? undefined;
    this.formatters = this.columns.map((column) => formatter(column.type, locale));
  }

  // The rows the grid lacks, asked for once the scrolling pauses.

  private planRequests(first: number, last: number): void {
    if (this.requestTimer) clearTimeout(this.requestTimer);
    if (this.cache.missing(first - PREFETCH, last + PREFETCH, this.total).length === 0) {
      this.stale = null;
      return;
    }
    const ask = () => {
      this.requestTimer = null;
      for (const block of this.cache.missing(first - PREFETCH, last + PREFETCH, this.total)) this.request(block);
    };
    if (this.urgent) {
      this.urgent = false;
      ask();
    } else {
      this.requestTimer = setTimeout(ask, REQUEST_DELAY);
    }
  }

  private request(block: number, then?: () => void): void {
    const cache = this.cache;
    cache.ask(block);
    this.transport.push("masu:rows", { from: block * cache.size, count: cache.size }, (reply) => {
      const answer = reply as unknown as BlockReply;
      // An answer is good when it has the grid's revision now, whatever
      // the revision was when the grid asked: under live changes the
      // server is often a revision ahead of the question.
      if (answer.revision !== this.revision) {
        cache.failed(block);
        this.schedule();
        return;
      }
      if (cache !== this.cache) cache.failed(block);
      this.cache.store(answer.from, answer.rows);
      if (answer.rows.length === 0) this.cache.failed(block);
      if (answer.total !== this.total) this.total = answer.total;
      this.schedule();
      then?.();
    });
  }

  /** Asks for the rows from `first` to `last` that the cache lacks, then calls `done`. */
  private load(first: number, last: number, done: () => void): void {
    const blocks = this.cache.missing(first, last, this.total);
    if (blocks.length === 0) {
      done();
      return;
    }
    let left = blocks.length;
    for (const block of blocks) {
      this.request(block, () => {
        left -= 1;
        if (left === 0) this.load(first, last, done);
      });
    }
  }

  // Events.

  private on<K extends keyof HTMLElementEventMap>(
    target: HTMLElement | Document | Window,
    type: K,
    listener: (event: HTMLElementEventMap[K]) => void,
    options?: AddEventListenerOptions,
  ): void {
    target.addEventListener(type, listener as EventListener, options);
    this.cleanups.push(() => target.removeEventListener(type, listener as EventListener, options));
  }

  private listen(): void {
    this.on(this.gridEl, "scroll", () => this.schedule(), { passive: true });
    this.on(this.gridEl, "keydown", (event) => this.onKeyDown(event));
    this.on(this.gridEl, "mousedown", (event) => this.onMouseDown(event));
    this.on(this.gridEl, "dblclick", (event) => this.onDoubleClick(event));
    this.on(this.gridEl, "click", (event) => {
      const button = (event.target as HTMLElement).closest<HTMLElement>(".masu-filter-button");
      if (!button) return;
      const col = Number(button.dataset.col);
      if (this.menu?.col === col) this.closeMenu(true);
      else this.openMenu(col);
    });
    this.on(this.chipsEl, "click", (event) => this.onChipClick(event));
    this.on(this.gridEl, "focus", () => this.schedule());
    this.on(document, "mousemove", (event) => this.onMouseMove(event));
    this.on(document, "mouseup", () => {
      this.dragging = false;
    });
    this.on(document, "copy", (event) => this.onCopy(event));
    this.on(document, "paste", (event) => this.onPaste(event));

    if (this.searchEl) {
      this.on(this.searchEl, "input", () => {
        if (this.searchTimer) clearTimeout(this.searchTimer);
        this.searchTimer = setTimeout(() => this.search(this.searchEl!.value), SEARCH_DELAY);
      });
      this.on(this.searchEl, "keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          if (this.searchTimer) clearTimeout(this.searchTimer);
          this.search(this.searchEl!.value);
        } else if (event.key === "ArrowDown") {
          event.preventDefault();
          this.gridEl.focus();
        }
      });
    }

    if (typeof ResizeObserver !== "undefined") {
      this.observer = new ResizeObserver(() => this.schedule());
      this.observer.observe(this.gridEl);
    }
  }

  private search(text: string): void {
    const search = text.trim() === "" ? null : text.trim();
    if (search === this.query.search) return;
    this.setQuery({ ...this.query, search });
  }

  private sortBy(col: number, additive: boolean): void {
    const column = this.columns[col];
    if (!column?.sortable) return;
    this.setQuery({ ...this.query, sorts: nextSorts(this.query.sorts, column.key, additive) });
  }

  private onKeyDown(event: KeyboardEvent): void {
    const mod = event.ctrlKey || event.metaKey;
    if (this.editor) return;
    if (this.onEditKey(event, mod)) return;

    if (mod && event.key.toLowerCase() === "a") {
      event.preventDefault();
      if (this.total === 0) return;
      this.anchor = { row: 0, col: 0 };
      this.active = { row: this.total - 1, col: this.columns.length - 1 };
      this.render();
      this.announce(this.message("selected", { count: this.total }));
      return;
    }

    if (event.key === "Escape" && this.anchor) {
      this.anchor = null;
      this.render();
      return;
    }

    if (event.altKey && event.key === "ArrowDown" && this.active.row === -1) {
      event.preventDefault();
      this.openMenu(this.active.col);
      return;
    }

    if ((event.key === "Enter" || event.key === " ") && this.active.row === -1) {
      event.preventDefault();
      this.sortBy(this.active.col, event.shiftKey);
      return;
    }

    const target = move(this.active, event.key, mod, {
      rows: this.total,
      cols: this.columns.length,
      page: this.pageRows(),
      rtl: getComputedStyle(this.gridEl).direction === "rtl",
    });
    if (!target) return;
    event.preventDefault();

    if (event.shiftKey && target.row >= 0) {
      if (!this.anchor) this.anchor = this.active.row >= 0 ? { ...this.active } : { row: 0, col: this.active.col };
    } else {
      this.anchor = null;
    }
    this.active = target;
    this.ensureVisible(target);
    this.render();
  }

  private onMouseDown(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    if (target.closest("a, button, input, select, textarea, label, [contenteditable]")) return;

    const resizer = target.closest<HTMLElement>(".masu-resizer");
    if (resizer) {
      event.preventDefault();
      this.startResize(event, Number(resizer.parentElement!.dataset.col));
      return;
    }

    const header = target.closest<HTMLElement>(".masu-hcell");
    if (header) {
      event.preventDefault();
      this.gridEl.focus({ preventScroll: true });
      const col = Number(header.dataset.col);
      this.active = { row: -1, col };
      this.anchor = null;
      this.sortBy(col, event.shiftKey);
      this.render();
      return;
    }

    const cell = this.cellAt(target);
    if (!cell) return;
    event.preventDefault();
    this.gridEl.focus({ preventScroll: true });
    if (event.shiftKey) {
      if (!this.anchor) this.anchor = this.active.row >= 0 ? { ...this.active } : cell;
    } else {
      this.anchor = cell;
    }
    this.active = cell;
    this.dragging = true;
    this.render();
  }

  private onMouseMove(event: MouseEvent): void {
    if (!this.dragging) return;
    const element = document.elementFromPoint(event.clientX, event.clientY) as HTMLElement | null;
    const cell = element && this.gridEl.contains(element) ? this.cellAt(element) : null;
    if (cell && (cell.row !== this.active.row || cell.col !== this.active.col)) {
      this.active = cell;
      this.render();
    }
  }

  private onDoubleClick(event: MouseEvent): void {
    const resizer = (event.target as HTMLElement).closest<HTMLElement>(".masu-resizer");
    if (resizer) {
      this.autosize(Number(resizer.parentElement!.dataset.col));
      return;
    }
    const cell = this.cellAt(event.target as HTMLElement);
    if (cell) this.startEdit(cell);
  }

  private cellAt(element: HTMLElement): Cell | null {
    const cellEl = element.closest<HTMLElement>(".masu-cell");
    const rowEl = cellEl?.parentElement as RowElement | null;
    if (!cellEl || !rowEl || rowEl.masuIndex === undefined) return null;
    return { row: rowEl.masuIndex, col: Array.prototype.indexOf.call(rowEl.children, cellEl) };
  }

  // Columns.

  private startResize(event: MouseEvent, col: number): void {
    const startX = event.clientX;
    const startWidth = this.widths[col];
    const sign = getComputedStyle(this.gridEl).direction === "rtl" ? -1 : 1;
    this.el.classList.add("masu-resizing");

    const onMove = (moveEvent: MouseEvent) => {
      this.setWidth(col, startWidth + sign * (moveEvent.clientX - startX));
    };
    const onUp = () => {
      this.el.classList.remove("masu-resizing");
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    };
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  private setWidth(col: number, width: number): void {
    this.widths[col] = Math.max(this.columns[col].minWidth, Math.round(width));
    this.applyWidths();
  }

  /** Fits a column to the widest of its header and the cells on the screen. */
  autosize(col: number): void {
    let widest = 0;
    const measure = (cell: Element | undefined) => {
      if (!(cell instanceof HTMLElement)) return;
      const style = getComputedStyle(cell);
      const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
      const content = Array.from(cell.children).reduce(
        (sum, child) => sum + (child instanceof HTMLElement ? child.scrollWidth : 0),
        0,
      );
      const text = cell.children.length === 0 ? textWidth(cell) : content;
      widest = Math.max(widest, text + padding);
    };
    measure(this.headerRow.children[col]);
    for (const rowEl of this.rows.values()) measure(rowEl.children[col]);
    this.setWidth(col, Math.min(Math.ceil(widest) + 4, MAX_AUTO_WIDTH));
  }


  // Editing. A cell of an editable column takes Enter, F2, a double click
  // or a key typed on it; its editor saves on Enter, Tab or a click away,
  // and gives up on Escape. The cell shows the new value at once, and the
  // old one again, with the server's error, if the server refuses it.

  private onEditKey(event: KeyboardEvent, mod: boolean): boolean {
    const { row, col } = this.active;
    const column = this.columns[col];
    const key = event.key;

    if (mod && !event.altKey && key.toLowerCase() === "z") {
      event.preventDefault();
      if (event.shiftKey) this.redo();
      else this.undo();
      return true;
    }
    if (mod && key.toLowerCase() === "y") {
      event.preventDefault();
      this.redo();
      return true;
    }
    if (row < 0 || !column) return false;
    if (mod && key.toLowerCase() === "d") {
      event.preventDefault();
      this.fillDown();
      return true;
    }
    if (!column.editable) return false;
    const data = this.cache.get(row) ?? this.stale?.get(row);
    if (data && this.locked(data, col)) return false;

    if (column.type === "boolean" && (key === " " || key === "Enter")) {
      event.preventDefault();
      const current = this.valueAt(row, col);
      this.applyEdits([{ row, col, value: !(current === true) }]);
      return true;
    }
    if (key === "Enter" || key === "F2") {
      event.preventDefault();
      this.startEdit(this.active);
      return true;
    }
    if (key === "Delete" || key === "Backspace") {
      event.preventDefault();
      this.clearCells();
      return true;
    }
    if (key.length === 1 && !mod && !event.altKey && column.type !== "boolean") {
      event.preventDefault();
      this.startEdit(this.active, key);
      return true;
    }
    return false;
  }

  /** Opens the editor of a cell, with its value, or with `text` typed on it. */
  startEdit(cell: Cell, text?: string): void {
    const column = this.columns[cell.col];
    const row = this.cache.get(cell.row) ?? this.stale?.get(cell.row);
    if (!column?.editable || !row || cell.row < 0 || this.locked(row, cell.col)) return;
    if (column.type === "boolean") return;

    this.active = { ...cell };
    this.anchor = null;
    this.ensureVisible(cell);
    const raw = rawValue(row[cell.col + 1]);

    const input = document.createElement("input");
    input.className = `masu-editor masu-align-${column.align}`;
    input.type = column.type === "date" ? "date" : column.type === "datetime" ? "datetime-local" : column.type === "time" ? "time" : "text";
    if (input.type !== "text") input.step = "1";
    if (column.type === "integer" || column.type === "number" || column.type === "decimal") input.inputMode = "decimal";
    input.setAttribute("aria-label", column.label);
    input.value = text ?? inputText(column.type, raw);
    input.style.transform = `translateY(${cell.row * this.config.rowHeight}px)`;
    input.style.insetInlineStart = `${this.widths.slice(0, cell.col).reduce((a, b) => a + b, 0)}px`;
    input.style.width = `${this.widths[cell.col]}px`;
    input.style.height = `${this.config.rowHeight}px`;

    this.editor = { input, row: cell.row, col: cell.col, id: row[0], original: raw, done: false };
    input.addEventListener("keydown", (event) => this.onEditorKey(event));
    input.addEventListener("blur", () => this.commitEdit(null));
    this.body.appendChild(input);
    input.focus();
    if (text === undefined && input.type === "text") input.setSelectionRange(input.value.length, input.value.length);
  }

  private onEditorKey(event: KeyboardEvent): void {
    event.stopPropagation();
    switch (event.key) {
      case "Enter":
        event.preventDefault();
        this.commitEdit({ row: event.shiftKey ? -1 : 1, col: 0 });
        break;
      case "Tab":
        event.preventDefault();
        this.commitEdit({ row: 0, col: event.shiftKey ? -1 : 1 });
        break;
      case "Escape":
        event.preventDefault();
        this.closeEditor();
        break;
    }
  }

  private commitEdit(step: { row: number; col: number } | null): void {
    const editor = this.editor;
    if (!editor || editor.done) return;
    editor.done = true;
    const column = this.columns[editor.col];
    const changed = editor.input.value !== inputText(column.type, editor.original);
    const value = sendValue(column.type, editor.input.value, this.config.locale ?? undefined);
    this.closeEditor();
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value }]);
    if (step) {
      this.active = {
        row: Math.min(Math.max(editor.row + step.row, 0), this.total - 1),
        col: Math.min(Math.max(editor.col + step.col, 0), this.columns.length - 1),
      };
      this.ensureVisible(this.active);
      this.render();
    }
  }

  private closeEditor(): void {
    const editor = this.editor;
    if (!editor) return;
    editor.done = true;
    this.editor = null;
    editor.input.remove();
    this.gridEl.focus({ preventScroll: true });
    this.render();
  }

  /**
   * Saves values in cells (of rows the browser has): shows them at once,
   * and asks the server to save them; a cell the server refuses shows its
   * old value again, with the error.
   */
  private applyEdits(cells: { row: number; col: number; value: string | boolean | null }[], record = true): void {
    const edits: Edit[] = [];
    let skipped = 0;
    for (const { row, col, value } of cells) {
      const column = this.columns[col];
      const data = this.cache.get(row) ?? this.stale?.get(row);
      if (!column?.editable || !data || this.locked(data, col)) {
        skipped += 1;
        continue;
      }
      const before = rawValue(data[col + 1]);
      edits.push({ id: data[0], key: column.key, col, row, before, value });
      this.setValue(row, col, column.html ? [escapeHTML(String(value ?? "")), shownValue(column.type, value)] : shownValue(column.type, value));
    }
    if (skipped > 0) this.announce(this.message("not_editable", { count: skipped }));
    this.send(edits, record ? "edit" : "redo");
  }

  private send(edits: Edit[], mode: "edit" | "undo" | "redo"): void {
    if (edits.length === 0) return;
    for (const edit of edits) {
      const key = cellKey(edit.id, edit.key);
      this.errors.delete(key);
      this.saving.add(key);
    }
    this.refreshRows();

    const payload = edits.map((edit) => ({ id: edit.id, key: edit.key, value: edit.value }));
    this.transport.push("masu:edit", { edits: payload }, (reply) => {
      const errors = (reply.errors as [unknown, string, string][]) ?? [];
      for (const edit of edits) this.saving.delete(cellKey(edit.id, edit.key));
      const refused = new Set<string>();
      for (const [id, key, message] of errors) {
        const cell = cellKey(id, key);
        refused.add(cell);
        this.errors.set(cell, message);
      }
      // A refused cell shows its old value until the rows come again.
      for (const edit of edits) {
        if (refused.has(cellKey(edit.id, edit.key)) && edit.row !== undefined) {
          const column = this.columns[edit.col];
          const shown = this.valueAt(edit.row, edit.col);
          if (shown !== undefined) this.setValue(edit.row, edit.col, column.html ? [escapeHTML(String(edit.before ?? "")), edit.before] : edit.before);
        }
      }

      const saved = edits.filter((edit) => !refused.has(cellKey(edit.id, edit.key)));
      if (saved.length > 0) {
        if (mode === "undo") this.redoStack.push(saved);
        else {
          this.undoStack.push(saved);
          if (this.undoStack.length > 100) this.undoStack.shift();
          if (mode === "edit") this.redoStack = [];
        }
      }

      if (errors.length > 0) {
        const [id, key, message] = errors[0];
        const column = this.columns.find((c) => c.key === key);
        const more = errors.length > 1 ? ` ${this.message("more_errors", { count: errors.length - 1 })}` : "";
        this.announce(`${column?.label ?? key}: ${message}${more}`);
        void id;
      } else if (edits.length > 1) {
        this.announce(this.message("saved", { count: saved.length }));
      }
      this.refreshRows();
    });
  }

  private undo(): void {
    const batch = this.undoStack.pop();
    if (!batch) return;
    this.send(batch.map((edit) => this.reverse(edit)), "undo");
  }

  private redo(): void {
    const batch = this.redoStack.pop();
    if (!batch) return;
    this.send(batch.map((edit) => this.reverse(edit)), "redo");
  }

  /** The edit that takes `edit` back. */
  private reverse(edit: Edit): Edit {
    const column = this.columns[edit.col];
    const value = edit.before === null ? null : typeof edit.before === "boolean" ? edit.before : sendValue(column.type, inputText(column.type, edit.before), undefined);
    return { ...edit, before: shownValue(column.type, edit.value), value, row: undefined };
  }

  private clearCells(): void {
    const selection = this.selection();
    if (!selection) return;
    this.withRows(selection, (cells) => this.applyEdits(cells.map(({ row, col }) => ({ row, col, value: null }))));
  }

  private fillDown(): void {
    const selection = this.selection();
    if (!selection || selection.bottom === selection.top) return;
    this.withRows(selection, (cells) => {
      const edits = cells
        .filter(({ row }) => row !== selection.top)
        .map(({ row, col }) => {
          const column = this.columns[col];
          const top = this.valueAt(selection.top, col) ?? null;
          const value = typeof top === "boolean" || top === null ? top : sendValue(column.type, inputText(column.type, top), undefined);
          return { row, col, value };
        });
      this.applyEdits(edits);
    });
  }

  private onPaste(event: ClipboardEvent): void {
    if (document.activeElement !== this.gridEl || this.editor) return;
    const text = event.clipboardData?.getData("text/plain");
    if (!text) return;
    event.preventDefault();
    const selection = this.selection() ?? { top: 0, left: 0, bottom: 0, right: 0 };
    const placed = placePaste(fromTSV(text), selection, this.total, this.columns.length).slice(0, MAX_EDITS);
    if (placed.length === 0) return;
    const bottom = Math.max(...placed.map((p) => p.row));
    const right = Math.max(...placed.map((p) => p.col));
    this.anchor = { row: selection.top, col: selection.left };
    this.active = { row: bottom, col: right };
    this.load(selection.top, bottom, () => {
      const locale = this.config.locale ?? undefined;
      this.applyEdits(placed.map((p) => ({ row: p.row, col: p.col, value: sendValue(this.columns[p.col].type, p.text, locale) })));
    });
  }

  /** The editable cells of a range, once the browser has its rows. */
  private withRows(range: Rect, then: (cells: Cell[]) => void): void {
    const last = Math.min(range.bottom, range.top + Math.floor(MAX_EDITS / (range.right - range.left + 1)) - 1);
    this.load(range.top, last, () => {
      const cells: Cell[] = [];
      for (let row = range.top; row <= last; row++) {
        for (let col = range.left; col <= range.right; col++) {
          if (this.columns[col].editable) cells.push({ row, col });
        }
      }
      then(cells);
    });
  }

  /** Whether the row's state makes its cell of `col` read-only. */
  private locked(data: Row, col: number): boolean {
    if (!this.config.locks) return false;
    const lock = (data as unknown[])[this.columns.length + 1];
    return lock === true || (Array.isArray(lock) && lock.includes(col));
  }

  private valueAt(row: number, col: number): CellValue | undefined {
    const data = this.cache.get(row) ?? this.stale?.get(row);
    return data ? rawValue(data[col + 1]) : undefined;
  }

  /** Puts a value in a row the browser has, in a new copy of the row. */
  private setValue(row: number, col: number, value: unknown): void {
    for (const cache of [this.cache, this.stale]) {
      const data = cache?.get(row);
      if (!cache || !data) continue;
      const copy = [...data] as Row;
      copy[col + 1] = value as CellValue;
      cache.store(row, [copy]);
    }
  }

  /** Draws the rows on the screen again, with their errors and marks. */
  private refreshRows(): void {
    for (const rowEl of this.rows.values()) rowEl.masuRow = undefined;
    this.render();
  }

  // Selection and copy.

  /** The cells a copy takes: the range, or the active cell. */
  private selection(): Rect | null {
    if (this.active.row < 0) return null;
    return rect(this.anchor ?? this.active, this.active);
  }

  /** The range that shows as selected: only one that the person made. */
  private highlight(): Rect | null {
    return this.anchor && this.active.row >= 0 ? rect(this.anchor, this.active) : null;
  }

  private onCopy(event: ClipboardEvent): void {
    if (document.activeElement !== this.gridEl) return;
    const selection = this.selection();
    if (!selection) return;
    const last = Math.min(selection.bottom, selection.top + MAX_COPY_ROWS - 1);

    if (this.cache.missing(selection.top, last, this.total).length === 0 && event.clipboardData) {
      event.preventDefault();
      event.clipboardData.setData("text/plain", this.copyText(selection.top, last, selection));
      this.announceCopy(last - selection.top + 1);
      return;
    }

    // Rows that the browser does not have yet: ask for them, then write
    // the clipboard when they come.
    event.preventDefault();
    this.announce(this.message("loading", {}));
    this.load(selection.top, last, () => {
      const text = this.copyText(selection.top, last, selection);
      navigator.clipboard?.writeText(text).then(
        () => this.announceCopy(last - selection.top + 1),
        () => this.announce(this.message("copy_failed", {})),
      );
    });
  }

  private copyText(first: number, last: number, selection: Rect): string {
    const lines: string[][] = [];
    if (selection.top === 0 && last === this.total - 1 && this.total > 1) {
      lines.push(this.columns.slice(selection.left, selection.right + 1).map((column) => column.label));
    }
    for (let index = first; index <= last; index++) {
      const row = this.cache.get(index);
      const line: string[] = [];
      for (let col = selection.left; col <= selection.right; col++) {
        const value = row ? (row[col + 1] as CellValue) : null;
        line.push(this.columns[col].html ? htmlText(Array.isArray(value) ? (value[0] as CellValue) : value) : copyText(value));
      }
      lines.push(line);
    }
    return toTSV(lines);
  }

  // Scrolling to a cell.

  private pageRows(): number {
    return Math.max(1, Math.floor((this.gridEl.clientHeight - this.head.offsetHeight) / this.config.rowHeight) - 1);
  }

  private ensureVisible(cell: Cell): void {
    const rh = this.config.rowHeight;
    const headHeight = this.head.offsetHeight;
    if (cell.row >= 0) {
      const top = cell.row * rh;
      const bottom = top + rh;
      const viewTop = this.gridEl.scrollTop;
      const viewBottom = viewTop + this.gridEl.clientHeight - headHeight;
      if (top < viewTop) this.gridEl.scrollTop = top;
      else if (bottom > viewBottom) this.gridEl.scrollTop = bottom - (this.gridEl.clientHeight - headHeight);
    }
    const left = this.widths.slice(0, cell.col).reduce((a, b) => a + b, 0);
    const right = left + this.widths[cell.col];
    const scrollLeft = Math.abs(this.gridEl.scrollLeft);
    if (left < scrollLeft) this.gridEl.scrollLeft = left;
    else if (right > scrollLeft + this.gridEl.clientWidth) this.gridEl.scrollLeft = right - this.gridEl.clientWidth;
  }

  // Words for a screen reader.

  private message(name: string, values: { count?: number; label?: string }): string {
    const messages = this.messages();
    const count = values.count ?? 0;
    const template = name === "rows" && count === 1 ? messages.row : messages[name] ?? name;
    const formatted = new Intl.NumberFormat(this.config.locale ?? undefined).format(count);
    return template.replace("{count}", formatted).replace("{label}", values.label ?? "");
  }

  private announceCount(): void {
    this.announce(this.message("rows", { count: this.total }));
  }

  private announceCopy(count: number): void {
    this.announce(this.message(count === 1 ? "copied_one" : "copied", { count }));
  }

  private announce(text: string): void {
    if (this.statusEl) this.statusEl.textContent = text;
  }
}

const DEFAULT_MESSAGES: Record<string, string> = {
  row: "{count} row",
  rows: "{count} rows",
  loading: "Loading",
  selected: "{count} rows selected",
  copied: "{count} rows copied",
  copied_one: "1 row copied",
  copy_failed: "The rows could not be copied",
  filter: "Filter {label}",
  condition: "Condition",
  apply: "Apply",
  clear: "Clear",
  clear_all: "Clear all",
  remove_filter: "Remove the filter",
  search_values: "Search values",
  no_values: "No values",
  empty_value: "(empty)",
  from: "From",
  to: "To",
  and: "and",
  yes: "Yes",
  no: "No",
  op_eq: "is",
  op_neq: "is not",
  op_contains: "contains",
  op_not_contains: "does not contain",
  op_starts_with: "starts with",
  op_ends_with: "ends with",
  op_gt: "greater than",
  op_gte: "at least",
  op_lt: "less than",
  op_lte: "at most",
  op_gt_time: "after",
  op_gte_time: "on or after",
  op_lt_time: "before",
  op_lte_time: "on or before",
  op_between: "between",
  op_in: "is one of",
  op_is_nil: "is empty",
  op_not_nil: "is not empty",
  not_editable: "{count} cells cannot be edited",
  saved: "{count} cells saved",
  more_errors: "({count} more)",
};

// A funnel, drawn for Masu.
const FILTER_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 3h11l-4.25 5v4.25l-2.5 1.25V8z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>';

interface Editor {
  input: HTMLInputElement;
  row: number;
  col: number;
  id: unknown;
  original: CellValue;
  done: boolean;
}

interface Edit {
  id: unknown;
  key: string;
  col: number;
  /** The row's index when the edit was made; undefined for an undo. */
  row: number | undefined;
  before: CellValue;
  value: string | boolean | null;
}

const MAX_EDITS = 5_000;

function cellKey(id: unknown, key: string): string {
  return `${JSON.stringify(id)}\u0000${key}`;
}

/** The value of a cell: an editable column of HEEx sends [html, value]. */
function rawValue(value: unknown): CellValue {
  return Array.isArray(value) ? (value[1] as CellValue) : (value as CellValue);
}

function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);
}

function readConfig(el: HTMLElement): Config {
  return JSON.parse(el.dataset.masu ?? "{}") as Config;
}

function htmlText(value: CellValue): string {
  if (typeof value !== "string" || value === "") return "";
  const template = document.createElement("template");
  template.innerHTML = value;
  return (template.content.textContent ?? "").replace(/\s+/g, " ").trim();
}

let measurer: HTMLCanvasElement | null = null;

function textWidth(cell: HTMLElement): number {
  measurer ??= document.createElement("canvas");
  const context = measurer.getContext("2d");
  if (!context) return cell.scrollWidth;
  const style = getComputedStyle(cell);
  context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  return context.measureText(cell.textContent ?? "").width;
}
