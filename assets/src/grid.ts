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

  private rows = new Map<number, RowElement>();
  private pool: RowElement[] = [];
  private active: Cell = { row: 0, col: 0 };
  private anchor: Cell | null = null;
  private dragging = false;
  private frame: number | null = null;
  private queries = 0;
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
        cell.innerHTML = (row[col + 1] as string | null) ?? "";
      } else {
        const value = row[col + 1] as CellValue;
        cell.textContent = this.formatters[col](value);
        cell.classList.toggle("masu-null", value === null);
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

      const resizer = document.createElement("span");
      resizer.className = "masu-resizer";
      resizer.setAttribute("aria-hidden", "true");
      cell.appendChild(resizer);
      return cell;
    });
    this.headerRow.replaceChildren(...cells);
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
    this.on(this.gridEl, "focus", () => this.schedule());
    this.on(document, "mousemove", (event) => this.onMouseMove(event));
    this.on(document, "mouseup", () => {
      this.dragging = false;
    });
    this.on(document, "copy", (event) => this.onCopy(event));

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
    if (resizer) this.autosize(Number(resizer.parentElement!.dataset.col));
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
        line.push(this.columns[col].html ? htmlText(value) : copyText(value));
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

  private message(name: string, values: { count?: number }): string {
    const messages = { ...DEFAULT_MESSAGES, ...this.config.messages };
    const count = values.count ?? 0;
    const template = name === "rows" && count === 1 ? messages.row : messages[name] ?? name;
    const formatted = new Intl.NumberFormat(this.config.locale ?? undefined).format(count);
    return template.replace("{count}", formatted);
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
};

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
