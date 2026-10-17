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
import { moveKey, pins, scrollFor, visualLeft, type Pins } from "./layout";
import { indexAt, rowTop, totalHeight, type Gap } from "./offsets";
import { ColumnsPanel, ViewsPanel } from "./panels";
import { nextSorts } from "./sorting";
import { toTSV } from "./tsv";
import { sameView } from "./view";
import type { BlockReply, CellValue, ColumnConfig, Config, Options, Person, QuerySpec, Row, Transport } from "./types";

const options: Options = {};

/**
 * Options of every grid of the page: `peerLabel`, a function that draws
 * the label of another person on their cell (Masu.Presence).
 */
export function configure(next: Options): void {
  Object.assign(options, next);
}

const OVERSCAN = 8;
const PREFETCH = 60;
const REQUEST_DELAY = 40;
const SEARCH_DELAY = 250;
const MAX_COPY_ROWS = 10_000;
const MAX_AUTO_WIDTH = 640;
const FLASH = 1600;
const CURSOR_DELAY = 150;

interface RowElement extends HTMLDivElement {
  masuIndex?: number;
  masuRow?: Row | null;
  masuTop?: number;
}

/** A row's place in a tree (Masu.Tree), after its cells. */
interface TreeNode {
  level: number;
  children: boolean;
  expanded: boolean;
  position: number;
  size: number;
}

export class Grid {
  readonly el: HTMLElement;
  readonly id: string;
  private transport: Transport;
  private config: Config;
  private columns: ColumnConfig[];
  private widths: number[];
  private formatters: Formatter[] = [];
  private aggregateFormatters: Formatter[] = [];
  /** The row of totals (Masu.Group). */
  private footEl: HTMLElement | null = null;
  private total: number;
  private revision: number;
  private query: QuerySpec;
  private cache = new BlockCache();
  /** The rows of the revision before, shown until the new ones come. */
  private stale: BlockCache | null = null;
  /** The rows on the screen are old: ask for them at once, not after a pause. */
  private urgent = false;

  /** The part of the grid the browser owns (phx-update="ignore"): menus go in it, out of the server's renders. */
  private uiEl: HTMLElement;
  /** The scroll box: the server's, for the details it renders in it. */
  private gridEl: HTMLElement;
  /** The header and the rows: the browser's (phx-update="ignore"). */
  private contentEl: HTMLElement;
  /** The open details, rendered by the server (the `:detail` slot), placed under their rows. */
  private detailsEl: HTMLElement | null;
  private gaps: (Gap & { el: HTMLElement })[] = [];
  private detailObserver: ResizeObserver | null = null;
  private patchObserver: MutationObserver | null = null;
  private head: HTMLElement;
  private headerRow: HTMLElement;
  private body: HTMLElement;
  private emptyEl: HTMLElement | null;
  private statusEl: HTMLElement | null;
  private searchEl: HTMLInputElement | null;
  private chipsEl: HTMLElement;
  private menu: { col: number; menu: FilterMenu } | null = null;
  /** Where the pinned columns stick. */
  private pinned: Pins = pins([], []);
  /** The toolbar's buttons and their menus. */
  private columnsButton: HTMLButtonElement | null = null;
  private viewsButton: HTMLButtonElement | null = null;
  private panel: { kind: "columns"; panel: ColumnsPanel } | { kind: "views"; panel: ViewsPanel } | null = null;
  /** A block of a revision the grid does not have yet (a layout's answer). */
  private pendingBlock: BlockReply | null = null;
  private lastNotice = 0;
  /** A press on a header: a click sorts, a drag moves the column. */
  private headerPress: { col: number; x: number; shift: boolean; moved: boolean; target: number | null } | null = null;
  private dropEl: HTMLElement | null = null;
  private resizing = false;

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
  private flash = new Map<string, { until: number; color: string | undefined }>();
  /** The other people who have the grid open, and their marks. */
  private people: Person[] = [];
  private peerEls: HTMLElement[] = [];
  private sentCursor = "null";
  /** The person this person follows (Figma's follow): the grid shows their view, and their place in it. */
  private following: string | null = null;
  /** The followed person as last seen, for the banner after they leave. */
  private followed: Person | null = null;
  /**
   * The person's own view and place, kept while they follow someone, and
   * after, while the grid still shows that person's view: "Back to your view".
   */
  private ownView: OwnView | null = null;
  /** A view of someone else's that the server refused: not asked for again. */
  private refusedView: string | null = null;
  private followEl: HTMLElement | null = null;
  /** A query is on its way to the server. */
  private querying = false;
  /** The next revision's rows are not the old ones moved (a tree's row opened): drop the old. */
  private freshRows = false;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
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

    // Only this grid's own elements: a detail may hold another grid.
    this.gridEl = el.querySelector<HTMLElement>(":scope > .masu-grid")!;
    this.uiEl = el.querySelector<HTMLElement>(":scope > .masu-ui") ?? el;
    this.contentEl = this.gridEl.querySelector<HTMLElement>(":scope > .masu-content") ?? this.gridEl;
    this.detailsEl = this.gridEl.querySelector<HTMLElement>(":scope > .masu-details");
    this.head = this.contentEl.querySelector<HTMLElement>(":scope > .masu-head")!;
    this.headerRow = this.head.querySelector<HTMLElement>(".masu-header")!;
    this.body = this.contentEl.querySelector<HTMLElement>(":scope > .masu-body")!;
    this.emptyEl = this.contentEl.querySelector<HTMLElement>(":scope > .masu-empty");
    this.statusEl = el.querySelector<HTMLElement>(":scope > .masu-status");
    this.searchEl = this.uiEl.querySelector<HTMLInputElement>(".masu-search");

    // The chips of the filters, above the grid, in the browser's part.
    this.chipsEl = document.createElement("div");
    this.chipsEl.className = "masu-chips";
    this.uiEl.appendChild(this.chipsEl);

    this.makeFormatters();
    if (this.config.initial) this.cache.store(this.config.initial.from, this.config.initial.rows);

    this.renderHeader();
    this.applyWidths();
    this.body.replaceChildren();
    this.renderToolbar();
    this.renderTotals();
    this.listen();
    this.watchPatches();
    this.render();
    this.showNotice();
  }

  /** The server rendered the grid again: new rows, columns or options. */
  update(): void {
    this.markFollowed();
    const config = readConfig(this.el);
    const previous = this.config;
    // The columns that show, in their order: the rows of others are of no use.
    const keysChanged = keysOf(config.columns) !== keysOf(previous.columns);
    const columnsChanged = JSON.stringify(withoutWidths(config.columns)) !== JSON.stringify(withoutWidths(previous.columns));
    const widthsChanged = JSON.stringify(config.columns.map((c) => [c.key, c.width])) !== JSON.stringify(previous.columns.map((c) => [c.key, c.width]));
    this.config = config;

    if (columnsChanged || (widthsChanged && !this.resizing)) {
      // Widths the server sends (a view applied) win; else the person's stay.
      const widths = new Map(this.columns.map((column, i) => [column.key, this.widths[i]]));
      const sent = new Map(previous.columns.map((column) => [column.key, column.width]));
      this.columns = config.columns;
      this.widths = this.columns.map((column) =>
        widthsChanged && sent.get(column.key) !== column.width ? column.width : (widths.get(column.key) ?? column.width),
      );
      this.makeFormatters();
      this.renderHeader();
      this.applyWidths();
      this.clearRows();
      this.pool = [];
    }
    if (keysChanged) {
      this.cache = new BlockCache(this.cache.size, this.cache.maxBlocks);
      this.stale = null;
      this.active = { row: this.active.row, col: Math.min(this.active.col, this.columns.length - 1) };
    }
    // A view applied by the server (a saved view, the URL) brings its
    // search; not over a search the person is typing.
    const search = config.query.search ?? "";
    if (this.searchEl && !this.searchTimer && search !== (previous.query.search ?? "") && search !== this.searchEl.value.trim()) {
      this.searchEl.value = search;
    }
    this.renderToolbar();
    this.renderTotals();
    this.showNotice();
    this.measureDetails();

    if (config.revision > this.revision) {
      // New rows from the server (a live change, or new rows of the
      // LiveView): the person keeps their place; the rows that changed
      // flash as they are drawn.
      const now = performance.now();
      for (const [id, flash] of this.flash) if (flash.until < now) this.flash.delete(id);
      for (const id of config.changed ?? []) {
        this.flash.set(String(id), { until: now + FLASH, color: config.changedBy?.[String(id)] });
      }
      this.revision = config.revision;
      this.total = config.total;
      this.query = config.query;
      // The rows of the older revision stay on the screen until the new
      // ones come, so that the grid does not blink as its rows change;
      // not when the columns moved.
      this.stale = keysChanged || this.freshRows ? null : this.cache;
      this.freshRows = false;
      this.cache = new BlockCache(this.cache.size, this.cache.maxBlocks);
      if (config.initial) this.cache.store(config.initial.from, config.initial.rows);
      if (this.pendingBlock?.revision === this.revision) this.cache.store(this.pendingBlock.from, this.pendingBlock.rows);
      this.pendingBlock = null;
      this.renderHeader();
      this.urgent = true;
    }

    this.render();
  }

  destroy(): void {
    this.closeMenu(false);
    this.closePanel(false);
    this.detailObserver?.disconnect();
    this.patchObserver?.disconnect();
    this.editor?.input.remove();
    this.editor = null;
    for (const cleanup of this.cleanups) cleanup();
    this.cleanups = [];
    this.observer?.disconnect();
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    if (this.requestTimer) clearTimeout(this.requestTimer);
    if (this.searchTimer) clearTimeout(this.searchTimer);
    if (this.cursorTimer) clearTimeout(this.cursorTimer);
  }

  // The query: a new order, filters or search, applied by the server.

  /**
   * Applies a view: the person's own (`self`), that of the person they
   * follow (`follow`), or their own again (`restore`). `then` runs once the
   * rows of the new view came.
   */
  setQuery(query: QuerySpec, origin: "self" | "follow" | "restore" = "self", then?: () => void): void {
    // A view of the person's own ends following, and the view kept aside.
    if (origin === "self") this.dropFollow();
    else if (this.searchEl) this.searchEl.value = query.search ?? "";

    // The new query shows at once, so that a second click builds on the
    // first; only the answer to the last query asked for is applied.
    const previous = this.query;
    const sent = ++this.queries;
    this.query = query;
    this.querying = true;
    this.renderHeader();
    this.el.classList.add("masu-busy");

    this.transport.push("masu:query", query, (reply) => {
      if (sent !== this.queries) return;
      this.querying = false;
      this.el.classList.remove("masu-busy");
      const answer = reply as unknown as BlockReply;
      if (answer.error) {
        if (origin === "follow") this.refusedView = JSON.stringify(query);
        this.query = previous;
        if (origin !== "self" && this.searchEl) this.searchEl.value = previous.search ?? "";
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
      if (origin === "self") this.announceCount();
      then?.();
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
    setStyle(this.body, "height", `${totalHeight(this.total, rh, this.gaps)}px`);
    setAttribute(this.gridEl, "aria-rowcount", String(this.total + 1));
    setAttribute(this.gridEl, "aria-colcount", String(this.columns.length));
    if (this.emptyEl) this.emptyEl.hidden = this.total > 0;

    const headHeight = this.head.offsetHeight;
    const { first, last } =
      this.gaps.length === 0
        ? visibleRows(this.gridEl.scrollTop, this.gridEl.clientHeight - headHeight, rh, this.total, OVERSCAN)
        : {
            first: Math.max(0, indexAt(this.gridEl.scrollTop, rh, this.gaps) - OVERSCAN),
            last: Math.min(this.total - 1, indexAt(this.gridEl.scrollTop + this.gridEl.clientHeight - headHeight, rh, this.gaps) + OVERSCAN),
          };

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
        rowEl.masuTop = undefined;
        rowEl.setAttribute("aria-rowindex", String(index + 2));
        this.body.appendChild(rowEl);
        this.rows.set(index, rowEl);
      }
      // A detail opened above it moves it down.
      const top = this.rowTop(index);
      if (rowEl.masuTop !== top) {
        rowEl.masuTop = top;
        rowEl.style.transform = `translateY(${top}px)`;
      }
      this.fillRow(rowEl, index, this.cache.get(index) ?? this.stale?.get(index) ?? null);
      this.markRow(rowEl, index, selection);
    }

    this.markHeader(selection);
    this.updateActiveDescendant();
    if (this.editor) this.editor.input.style.insetInlineStart = `${this.colLeft(this.editor.col)}px`;
    this.placeDetails(headHeight);
    this.drawPeople();
    this.reportCursor();
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
    this.pin(cell, col);
    return cell;
  }

  /** A cell of a pinned column sticks to its edge, at its offset. */
  private pin(cell: HTMLElement, col: number): void {
    const pinned = this.columns[col].pinned;
    if (!pinned) return;
    cell.classList.add("masu-pinned", `masu-pinned-${pinned}`);
    // The last pinned to the start and the first pinned to the end draw
    // the edge.
    const edge = pinned === "start" ? this.columns[col + 1]?.pinned !== "start" : this.columns[col - 1]?.pinned !== "end";
    if (edge) cell.classList.add("masu-pinned-edge");
    if (pinned === "start") cell.style.insetInlineStart = `var(--masu-pin-${col})`;
    else cell.style.insetInlineEnd = `var(--masu-pin-${col})`;
  }

  /** Where a column's cells are on the rows, with the scroll: a pinned one sticks. */
  private colLeft(col: number): number {
    return visualLeft(col, this.widths, this.pinned, Math.abs(this.gridEl.scrollLeft), this.gridEl.clientWidth);
  }

  private fillRow(rowEl: RowElement, index: number, row: Row | null): void {
    if (rowEl.masuRow === row && rowEl.masuIndex === index && rowEl.dataset.index === String(index)) return;
    rowEl.masuRow = row;
    rowEl.dataset.index = String(index);
    rowEl.classList.toggle("masu-loading", row === null);
    rowEl.setAttribute("aria-busy", row === null ? "true" : "false");

    rowEl.classList.toggle("masu-group-row", row !== null && isGroup(row));
    const flash = row === null ? null : this.flashing(row[0]);
    rowEl.classList.toggle("masu-changed", flash !== null);
    // The flash of a row someone saved takes their color.
    if (flash?.color) rowEl.style.setProperty("--masu-flash", flash.color);
    else rowEl.style.removeProperty("--masu-flash");

    const cells = rowEl.children;
    this.columns.forEach((column, col) => {
      const cell = cells[col] as HTMLElement;
      cell.id = `${this.id}-r${index}-c${col}`;
      if (row === null) {
        cell.textContent = "";
      } else if (isGroup(row)) {
        // A group's row: its totals, in their columns.
        const value = row[col + 1] as CellValue;
        cell.textContent = value === null ? "" : this.aggregateFormat(col)(value);
        cell.classList.remove("masu-null");
      } else if (column.html) {
        const value = row[col + 1] as unknown;
        cell.innerHTML = (Array.isArray(value) ? (value[0] as string) : (value as string | null)) ?? "";
      } else {
        const value = row[col + 1] as CellValue;
        cell.textContent = this.formatters[col](value);
        cell.classList.toggle("masu-null", value === null);
      }
      if (col === 0) this.decorateFirstCell(cell, row);

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

    // A row of a tree says where it is.
    const node = row === null ? null : this.nodeOf(row);
    if (node) {
      rowEl.setAttribute("aria-level", String(node.level + 1));
      rowEl.setAttribute("aria-posinset", String(node.position));
      rowEl.setAttribute("aria-setsize", String(node.size));
      if (node.children) rowEl.setAttribute("aria-expanded", String(node.expanded));
      else rowEl.removeAttribute("aria-expanded");
    } else {
      for (const name of ["aria-level", "aria-posinset", "aria-setsize", "aria-expanded"]) rowEl.removeAttribute(name);
    }
  }

  /** The place in the tree of a row (Masu.Tree), after its cells and its read-only cells. */
  private nodeOf(row: Row): TreeNode | null {
    if (!this.config.tree) return null;
    const meta = (row as unknown[])[this.columns.length + 1 + (this.config.locks ? 1 : 0)];
    if (!Array.isArray(meta)) return null;
    const [level, children, expanded, position, size] = meta as [number, boolean, boolean, number, number];
    return { level, children, expanded, position, size };
  }

  /** The first cell of a row: its indent and arrow in a tree, the arrow of its detail. */
  private decorateFirstCell(cell: HTMLElement, row: Row | null): void {
    if (!this.config.tree && !this.config.detail) return;
    const node = row === null ? null : this.nodeOf(row);
    cell.classList.toggle("masu-tree-cell", node !== null);
    if (node) cell.style.setProperty("--masu-level", String(node.level));
    else cell.style.removeProperty("--masu-level");
    if (row === null) return;

    if (node && isGroup(row)) {
      // A group's label: its column, its value, how many rows.
      const meta = (row as unknown[])[this.columns.length + 2 + (this.config.locks ? 1 : 0)] as [string, CellValue, number];
      const [key, value, count] = meta;
      const column = this.catalogColumn(key);
      const label = document.createElement("span");
      label.className = "masu-group-label";
      const shown = column ? formatter(column.type, this.config.locale ?? undefined)(value) : String(value);
      label.textContent = `${column?.label ?? key}: ${value === null ? this.message("empty_value", {}) : shown}`;
      const counter = document.createElement("span");
      counter.className = "masu-group-count";
      counter.textContent = new Intl.NumberFormat(this.config.locale ?? undefined).format(count);
      cell.replaceChildren(label, counter);
    }

    if (this.config.detail && !isGroup(row)) {
      const toggle = document.createElement("span");
      toggle.className = "masu-detail-toggle";
      toggle.setAttribute("aria-hidden", "true");
      toggle.dataset.open = String(this.openDetails().has(JSON.stringify(row[0])));
      cell.prepend(toggle);
    }
    if (node) {
      const twisty = document.createElement("span");
      twisty.className = "masu-twisty";
      twisty.setAttribute("aria-hidden", "true");
      twisty.dataset.state = node.children ? (node.expanded ? "open" : "closed") : "leaf";
      cell.prepend(twisty);
    }
  }

  /** The ids of the rows whose detail is open (as JSON). */
  private openDetails(): Set<string> {
    return new Set((this.config.details ?? []).map(([id]) => JSON.stringify(id)));
  }

  /** The top of a row, under the details open above it. */
  private rowTop(index: number): number {
    return rowTop(index, this.config.rowHeight, this.gaps);
  }

  /** The row at the top of the screen. */
  private indexAtTop(): number {
    return indexAt(this.gridEl.scrollTop, this.config.rowHeight, this.gaps);
  }

  /** The first row the screen shows whole: where one who follows this person starts. */
  private firstWholeRow(): number {
    const index = this.indexAtTop();
    return this.rowTop(index) < this.gridEl.scrollTop ? index + 1 : index;
  }

  // Details: the server renders the open ones (the `:detail` slot) in the
  // scroll box; the browser places each under its row, at the start of
  // the screen, as wide as the screen, and moves the rows under it down by
  // its height.

  /** Reads the open details and their heights. */
  private measureDetails(): void {
    if (!this.detailsEl) return;
    const els = new Map<string, HTMLElement>();
    for (const el of this.detailsEl.children) {
      if (el instanceof HTMLElement && el.dataset.id) els.set(el.dataset.id, el);
    }
    const before = JSON.stringify(this.gaps.map((gap) => [gap.index, gap.height]));
    const width = `${this.gridEl.clientWidth}px`;
    this.gaps = (this.config.details ?? [])
      .flatMap(([id, index]) => {
        const el = els.get(JSON.stringify(id));
        if (!el) return [];
        setStyle(el, "width", width);
        return [{ index, height: el.offsetHeight, el }];
      })
      .sort((a, b) => a.index - b.index);

    this.detailObserver ??= new ResizeObserver(() => {
      const heights = JSON.stringify(this.gaps.map((gap) => gap.el.offsetHeight));
      if (heights === JSON.stringify(this.gaps.map((gap) => gap.height))) return;
      this.measureDetails();
    });
    this.detailObserver.disconnect();
    for (const gap of this.gaps) this.detailObserver.observe(gap.el);
    this.observeDetailStyles();

    if (JSON.stringify(this.gaps.map((gap) => [gap.index, gap.height])) !== before) {
      for (const rowEl of this.rows.values()) rowEl.masuRow = undefined;
      this.render();
    }
  }

  private placeDetails(headHeight: number): void {
    const rh = this.config.rowHeight;
    const left = Math.abs(this.gridEl.scrollLeft);
    for (const gap of this.gaps) {
      setStyle(gap.el, "transform", `translate(${left}px, ${headHeight + this.rowTop(gap.index) + rh}px)`);
    }
  }

  /**
   * The server renders the scroll box and the details again: what the
   * browser set on them (the active cell, the details' places) is set
   * again, before the screen is drawn.
   */
  private watchPatches(): void {
    this.patchObserver = new MutationObserver((records) => {
      if (records.some((record) => record.target === this.gridEl && record.attributeName === "aria-activedescendant")) {
        this.updateActiveDescendant();
      }
      if (records.some((record) => record.target !== this.gridEl)) this.measureDetails();
      this.placeDetails(this.head.offsetHeight);
    });
    this.patchObserver.observe(this.gridEl, { attributes: true, attributeFilter: ["aria-activedescendant"] });
    if (this.detailsEl) this.patchObserver.observe(this.detailsEl, { childList: true, attributes: true, subtree: false });
    this.observeDetailStyles();
  }

  /** Each detail's style, which a render of the server takes away. */
  private observeDetailStyles(): void {
    if (!this.detailsEl || !this.patchObserver) return;
    for (const el of this.detailsEl.children) {
      this.patchObserver.observe(el, { attributes: true, attributeFilter: ["style"] });
    }
  }

  /** Whether an event comes from a detail (which may hold a grid of its own). */
  private inDetail(target: EventTarget | null): boolean {
    return this.detailsEl !== null && target instanceof Node && this.detailsEl.contains(target);
  }

  /** Opens or closes a row of the tree, or every row beside it (`*`). */
  private toggleNode(index: number, open: boolean, siblings = false): void {
    const row = this.cache.get(index) ?? this.stale?.get(index);
    if (!row) return;
    // The rows under it move: the old ones are of no use.
    this.freshRows = true;
    const from = Math.max(0, this.indexAtTop() - OVERSCAN);
    this.transport.push("masu:toggle", { id: row[0], open, siblings, from }, (reply) => {
      const answer = reply as unknown as BlockReply | null;
      if (answer?.rows) this.takeBlock(answer);
    });
  }

  /** Opens or closes the detail of a row. */
  private toggleDetail(index: number, open?: boolean): void {
    const row = this.cache.get(index) ?? this.stale?.get(index);
    if (!row || !this.config.detail) return;
    const isOpen = this.openDetails().has(JSON.stringify(row[0]));
    const next = open ?? !isOpen;
    if (next === isOpen) return;
    this.transport.push("masu:detail", { id: row[0], open: next });
    this.announce(this.message(next ? "detail_shown" : "detail_hidden", {}));
  }

  /** Moves the focus into the open detail of a row: its first control, or the detail. */
  private focusDetail(index: number): boolean {
    const gap = this.gaps.find((g) => g.index === index);
    if (!gap) return false;
    const target =
      gap.el.querySelector<HTMLElement>('.masu-grid, a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])') ??
      gap.el;
    if (target === gap.el) gap.el.tabIndex = -1;
    target.focus();
    return true;
  }

  private flashing(id: unknown): { color: string | undefined } | null {
    const flash = this.flash.get(String(id));
    if (flash === undefined) return null;
    if (performance.now() <= flash.until) return flash;
    this.flash.delete(String(id));
    return null;
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
    // Set only when it changes: the patch watcher hears every set.
    if (document.getElementById(id) && this.total + 1 > 0) setAttribute(this.gridEl, "aria-activedescendant", id);
    else if (this.gridEl.hasAttribute("aria-activedescendant")) this.gridEl.removeAttribute("aria-activedescendant");
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
      this.pin(cell, col);

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
    const groups = (this.query.groups ?? []).flatMap((key) => {
      const column = this.catalogColumn(key);
      if (!column) return [];
      const chip = document.createElement("span");
      chip.className = "masu-chip masu-chip-group";
      const text = document.createElement("span");
      text.className = "masu-chip-text";
      text.textContent = this.message("grouped_by", { label: column.label });
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "masu-chip-remove";
      remove.dataset.group = key;
      remove.setAttribute("aria-label", this.message("ungroup_by", { label: column.label }));
      remove.textContent = "×";
      chip.append(text, remove);
      return [chip];
    });

    const chips = this.query.filters.flatMap((filter) => {
      // A filter on a hidden column keeps its chip, which opens no menu.
      const col = this.columns.findIndex((column) => column.key === filter.key);
      const column = col >= 0 ? this.columns[col] : this.catalogColumn(filter.key);
      if (!column) return [];
      const format = col >= 0 ? this.formatters[col] : formatter(column.type, this.config.locale ?? undefined);
      const chip = document.createElement("span");
      chip.className = "masu-chip";
      const text = document.createElement("button");
      text.type = "button";
      text.className = "masu-chip-text";
      if (col >= 0) text.dataset.col = String(col);
      else text.disabled = true;
      text.textContent = describe(filter, column, (value) => format(value as CellValue), messages);
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
    this.chipsEl.replaceChildren(...groups, ...chips);
    this.chipsEl.hidden = groups.length + chips.length === 0;
  }

  /** A column of the grid, shown or hidden, as a column's config (for its label and type). */
  private catalogColumn(key: string): ColumnConfig | null {
    const shown = this.columns.find((column) => column.key === key);
    if (shown) return shown;
    const entry = this.config.catalog?.find((column) => column.key === key);
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
    const groups = (this.query.groups ?? []).filter((k) => k !== key);
    this.setQuery({ ...this.query, groups: on ? [...groups, key] : groups });
  }

  private onChipClick(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    const remove = target.closest<HTMLElement>(".masu-chip-remove");
    if (remove?.dataset.group) {
      this.groupBy(remove.dataset.group, false);
      return;
    }
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
        root: this.uiEl,
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
        group:
          this.config.groupable && column.sortable
            ? (on) => {
                this.closeMenu(true);
                this.groupBy(column.key, on);
              }
            : undefined,
        grouped: (this.query.groups ?? []).includes(column.key),
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
    this.contentEl.style.setProperty("--masu-cols", this.widths.map((width) => `${width}px`).join(" "));
    this.contentEl.style.setProperty("--masu-width", `${this.widths.reduce((a, b) => a + b, 0)}px`);
    this.pinned = pins(
      this.columns.map((column) => column.pinned ?? null),
      this.widths,
    );
    for (const [col, offset] of [...this.pinned.start, ...this.pinned.end]) {
      this.contentEl.style.setProperty(`--masu-pin-${col}`, `${offset}px`);
    }
  }

  private makeFormatters(): void {
    const locale = this.config.locale ?? undefined;
    this.formatters = this.columns.map((column) => formatter(column.type, locale));
    // A count is an integer; an average of integers has decimals.
    this.aggregateFormatters = this.columns.map((column, col) =>
      column.aggregate === "count" || column.aggregate === "count_distinct"
        ? formatter("integer", locale)
        : column.aggregate === "avg" && column.type === "integer"
          ? formatter("number", locale)
          : this.formatters[col],
    );
  }

  private aggregateFormat(col: number): Formatter {
    return this.aggregateFormatters[col] ?? this.formatters[col];
  }

  /** The row of totals of the query, at the bottom of the grid (Masu.Group). */
  private renderTotals(): void {
    const totals = this.config.totals;
    if (!totals) {
      this.footEl?.remove();
      this.footEl = null;
      return;
    }
    if (!this.footEl) {
      this.footEl = document.createElement("div");
      this.footEl.className = "masu-foot";
      this.footEl.setAttribute("role", "rowgroup");
      this.body.after(this.footEl);
    }
    const row = document.createElement("div");
    row.className = "masu-row masu-totals";
    row.setAttribute("role", "row");
    row.setAttribute("aria-label", this.message("totals", {}));
    this.columns.forEach((column, col) => {
      const cell = this.makeCell(column, col);
      cell.removeAttribute("aria-colindex");
      const value = totals[column.key];
      if (value !== undefined && value !== null) cell.textContent = this.aggregateFormat(col)(value);
      else if (col === 0) cell.textContent = this.message("totals", {});
      row.appendChild(cell);
    });
    this.footEl.replaceChildren(row);
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
    // A detail's own keys and clicks are its own (it may hold a grid).
    this.on(this.gridEl, "keydown", (event) => {
      if (this.inDetail(event.target)) this.onDetailKey(event);
      else this.onKeyDown(event);
    });
    this.on(this.gridEl, "mousedown", (event) => {
      if (!this.inDetail(event.target)) this.onMouseDown(event);
    });
    this.on(this.gridEl, "dblclick", (event) => {
      if (!this.inDetail(event.target)) this.onDoubleClick(event);
    });
    this.on(this.gridEl, "click", (event) => {
      if (this.inDetail(event.target)) return;
      const button = (event.target as HTMLElement).closest<HTMLElement>(".masu-filter-button");
      if (!button) return;
      const col = Number(button.dataset.col);
      if (this.menu?.col === col) this.closeMenu(true);
      else this.openMenu(col);
    });
    this.on(this.chipsEl, "click", (event) => this.onChipClick(event));
    this.on(this.el, "click", (event) => {
      const person = (event.target as HTMLElement).closest<HTMLElement>(".masu-person[data-person]");
      if (person && person.closest(".masu") === this.el) this.toggleFollow(person.dataset.person!);
    });
    // The person's own scrolling, clicking or typing ends a follow.
    for (const type of ["wheel", "touchstart", "mousedown", "keydown"] as const) {
      this.on(this.gridEl, type, () => this.stopFollowing(false), { passive: true });
    }
    this.on(this.gridEl, "focus", () => this.schedule());
    this.on(document, "mousemove", (event) => this.onMouseMove(event));
    this.on(document, "mouseup", () => {
      this.dragging = false;
      this.releaseHeader();
    });
    this.on(document, "copy", (event) => this.onCopy(event));
    this.on(document, "paste", (event) => this.onPaste(event));

    if (this.searchEl) {
      this.on(this.searchEl, "input", () => {
        if (this.searchTimer) clearTimeout(this.searchTimer);
        this.searchTimer = setTimeout(() => {
          this.searchTimer = null;
          this.search(this.searchEl!.value);
        }, SEARCH_DELAY);
      });
      this.on(this.searchEl, "keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          if (this.searchTimer) clearTimeout(this.searchTimer);
          this.searchTimer = null;
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
    if (this.onRowKey(event, mod)) return;
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
      // Taken: a grid around this one (in a detail) leaves the focus here.
      event.preventDefault();
      this.anchor = null;
      this.render();
      return;
    }

    if (event.altKey && event.shiftKey && this.active.row === -1 && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      const rtl = getComputedStyle(this.gridEl).direction === "rtl";
      this.moveColumn(this.active.col, (event.key === "ArrowRight") !== rtl ? 1 : -1);
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

  /**
   * The keys of a row: in a tree, → opens the row of the active cell of the
   * first column, ← closes it (or goes to its parent), * opens every row
   * beside it; Alt+→ and Alt+← open and close a row's detail, Alt+↓ goes
   * into it.
   */
  private onRowKey(event: KeyboardEvent, mod: boolean): boolean {
    const { row, col } = this.active;
    if (row < 0 || mod) return false;
    const data = this.cache.get(row) ?? this.stale?.get(row);
    if (!data) return false;

    if (event.altKey && this.config.detail) {
      if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
        event.preventDefault();
        this.toggleDetail(row, event.key === "ArrowRight");
        return true;
      }
      if (event.key === "ArrowDown" && this.focusDetail(row)) {
        event.preventDefault();
        return true;
      }
    }

    const node = this.nodeOf(data);
    if (!node || col !== 0 || event.altKey) return false;
    // * takes Shift on most keyboards; the arrows with Shift select.
    if (event.key === "*") {
      event.preventDefault();
      this.toggleNode(row, true, true);
      return true;
    }
    if (event.shiftKey) return false;
    if (event.key === "ArrowRight" && node.children && !node.expanded) {
      event.preventDefault();
      this.toggleNode(row, true);
      return true;
    }
    if (event.key === "ArrowLeft") {
      if (node.children && node.expanded) {
        event.preventDefault();
        this.toggleNode(row, false);
        return true;
      }
      if (node.level > 0) {
        // To the parent: the row above with a smaller level.
        for (let index = row - 1; index >= 0; index--) {
          const above = this.cache.get(index) ?? this.stale?.get(index);
          const aboveNode = above ? this.nodeOf(above) : null;
          if (aboveNode && aboveNode.level < node.level) {
            event.preventDefault();
            this.active = { row: index, col };
            this.anchor = null;
            this.ensureVisible(this.active);
            this.render();
            return true;
          }
        }
      }
    }
    return false;
  }

  /** Escape in a detail gives the focus back to its row. */
  private onDetailKey(event: KeyboardEvent): void {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    const gap = this.gaps.find((g) => g.el.contains(event.target as Node));
    if (!gap) return;
    event.preventDefault();
    this.active = { row: gap.index, col: Math.max(0, this.active.col) };
    this.anchor = null;
    this.gridEl.focus({ preventScroll: true });
    this.ensureVisible(this.active);
    this.render();
  }

  private onMouseDown(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    // The arrow of a tree's row, and of a detail.
    const arrow = target.closest<HTMLElement>(".masu-twisty, .masu-detail-toggle");
    if (arrow) {
      const cell = this.cellAt(arrow);
      if (cell) {
        event.preventDefault();
        this.gridEl.focus({ preventScroll: true });
        this.active = cell;
        this.anchor = null;
        this.render();
        if (arrow.classList.contains("masu-detail-toggle")) this.toggleDetail(cell.row);
        else if (arrow.dataset.state !== "leaf") this.toggleNode(cell.row, arrow.dataset.state === "closed");
        return;
      }
    }
    if (target.closest("a, button, input, select, textarea, label, [contenteditable]")) return;

    const resizer = target.closest<HTMLElement>(".masu-resizer");
    if (resizer) {
      event.preventDefault();
      this.startResize(event, Number(resizer.parentElement!.dataset.col));
      return;
    }

    const header = target.closest<HTMLElement>(".masu-hcell");
    if (header) {
      // A click sorts (on the release); a drag moves the column.
      event.preventDefault();
      this.gridEl.focus({ preventScroll: true });
      const col = Number(header.dataset.col);
      this.active = { row: -1, col };
      this.anchor = null;
      this.headerPress = { col, x: event.clientX, shift: event.shiftKey, moved: false, target: null };
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
    if (this.headerPress) {
      this.dragHeader(event);
      return;
    }
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
    if (!cellEl || !rowEl || rowEl.masuIndex === undefined || rowEl.parentElement !== this.body) return null;
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
    this.resizing = true;
    const onUp = () => {
      this.resizing = false;
      this.el.classList.remove("masu-resizing");
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      this.reportWidth(col);
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
    this.reportWidth(col);
  }

  // Layout: the toolbar's menus, moving, hiding, pinning and resizing
  // columns. The server keeps the layout (it is part of the person's
  // view) and sends the columns again; when the columns that show move,
  // the browser drops its rows, and the server's answer has those on the
  // screen.

  /** Tells the server of a change of layout, with where the screen starts. */
  private sendLayout(changes: { order?: string[]; hidden?: string[]; pinned?: Record<string, string>; widths?: Record<string, number> }): void {
    const from = Math.max(0, this.indexAtTop() - OVERSCAN);
    this.transport.push("masu:layout", { ...changes, from }, (reply) => {
      const answer = reply as unknown as BlockReply | null;
      if (answer?.rows) this.takeBlock(answer);
    });
  }

  /** A block of rows from an answer: of this revision, or of the next, which comes with the server's render. */
  private takeBlock(answer: BlockReply): void {
    if (answer.revision === this.revision) {
      this.cache.store(answer.from, answer.rows);
      this.schedule();
    } else if (answer.revision > this.revision) {
      this.pendingBlock = answer;
    }
  }

  private reportWidth(col: number): void {
    const column = this.columns[col];
    if (column) this.sendLayout({ widths: { [column.key]: this.widths[col] } });
  }

  /** Moves a column one place, among the columns of its pin. */
  private moveColumn(col: number, step: -1 | 1): void {
    const column = this.columns[col];
    const other = this.columns[col + step];
    if (!column || !other || (column.pinned ?? null) !== (other.pinned ?? null)) return;
    const order = this.config.catalog.map((c) => c.key);
    const moved = step < 0 ? moveKey(order, column.key, other.key) : moveKey(order, other.key, column.key);
    this.active = { row: -1, col: col + step };
    this.sendLayout({ order: moved });
    this.announce(this.message("moved", { label: column.label }));
  }

  private dragHeader(event: MouseEvent): void {
    const press = this.headerPress!;
    if (!press.moved && Math.abs(event.clientX - press.x) < 5) return;
    press.moved = true;
    this.el.classList.add("masu-moving");

    // The place among the columns of its pin: before the first whose middle is past the pointer.
    const pin = this.columns[press.col].pinned ?? null;
    const cells = Array.from(this.headerRow.children) as HTMLElement[];
    const zone = this.columns.map((c, col) => ({ c, col })).filter(({ c }) => (c.pinned ?? null) === pin);
    const rtl = getComputedStyle(this.gridEl).direction === "rtl";
    let target = zone[zone.length - 1].col + 1;
    for (const { col } of zone) {
      const box = cells[col].getBoundingClientRect();
      const middle = box.left + box.width / 2;
      if (rtl ? event.clientX > middle : event.clientX < middle) {
        target = col;
        break;
      }
    }
    press.target = target;

    this.dropEl ??= Object.assign(document.createElement("div"), { className: "masu-drop" });
    if (!this.dropEl.isConnected) this.head.appendChild(this.dropEl);
    const edge = target < this.columns.length ? this.colLeft(target) : this.colLeft(target - 1) + this.widths[target - 1];
    this.dropEl.style.insetInlineStart = `${edge - 1}px`;
    for (const cell of cells) cell.classList.toggle("masu-dragged", Number(cell.dataset.col) === press.col);
  }

  private releaseHeader(): void {
    const press = this.headerPress;
    if (!press) return;
    this.headerPress = null;
    this.dropEl?.remove();
    this.el.classList.remove("masu-moving");
    for (const cell of this.headerRow.children) cell.classList.remove("masu-dragged");

    if (!press.moved) {
      this.sortBy(press.col, press.shift);
      return;
    }
    const target = press.target;
    if (target === null || target === press.col || target === press.col + 1) return;
    const column = this.columns[press.col];
    const order = this.config.catalog.map((c) => c.key);
    let moved: string[];
    if (target < this.columns.length && (this.columns[target].pinned ?? null) === (column.pinned ?? null)) {
      moved = moveKey(order, column.key, this.columns[target].key);
    } else {
      // After the last column of its pin.
      const last = this.columns[target - 1].key;
      moved = moveKey(moveKey(order, column.key, last), last, column.key);
    }
    this.active = { row: -1, col: target > press.col ? target - 1 : target };
    this.sendLayout({ order: moved });
    this.announce(this.message("moved", { label: column.label }));
  }

  /** The toolbar's buttons: the columns menu and the views menu. */
  private renderToolbar(): void {
    const wanted = this.config.columnsMenu || this.config.views !== null;
    if (!wanted && !this.columnsButton && !this.viewsButton) return;

    let toolbar = this.uiEl.querySelector<HTMLElement>(":scope > .masu-toolbar");
    if (!toolbar) {
      toolbar = document.createElement("div");
      toolbar.className = "masu-toolbar";
      this.uiEl.prepend(toolbar);
    }
    let actions = toolbar.querySelector<HTMLElement>(".masu-toolbar-actions");
    if (!actions) {
      actions = document.createElement("div");
      actions.className = "masu-toolbar-actions";
      toolbar.appendChild(actions);
    }

    if (this.config.columnsMenu && !this.columnsButton) {
      this.columnsButton = toolbarButton(this.message("columns_menu", {}), "masu-columns-button", COLUMNS_ICON);
      this.columnsButton.addEventListener("click", () => this.togglePanel("columns"));
      actions.appendChild(this.columnsButton);
    }
    if (this.config.views !== null && !this.viewsButton) {
      this.viewsButton = toolbarButton(this.message("views_menu", {}), "masu-views-button", VIEWS_ICON);
      this.viewsButton.addEventListener("click", () => this.togglePanel("views"));
      actions.appendChild(this.viewsButton);
    }
    if (this.viewsButton) {
      // The button says which named view shows, if one does: the person's
      // own first, when a shared one is the same.
      const views = this.config.views ?? [];
      const current = views.find((view) => view.current && view.mine) ?? views.find((view) => view.current);
      const text = this.viewsButton.querySelector(".masu-toolbar-text")!;
      text.textContent = current ? current.name : this.message("views_menu", {});
      if (current) this.viewsButton.setAttribute("aria-label", this.message("views_current", { label: current.name }));
      else this.viewsButton.removeAttribute("aria-label");
    }

    if (this.panel?.kind === "columns") this.panel.panel.refresh();
    if (this.panel?.kind === "views") this.panel.panel.refresh();
  }

  private togglePanel(kind: "columns" | "views"): void {
    const open = this.panel?.kind;
    this.closePanel(false);
    if (open === kind) return;
    this.closeMenu(false);
    const messages = this.messages();

    if (kind === "columns") {
      const panel = new ColumnsPanel(
        {
          root: this.uiEl,
          messages,
          catalog: () => this.config.catalog,
          change: (layout) => this.sendLayout(layout),
          close: () => this.closePanel(true),
        },
        this.columnsButton!,
      );
      this.panel = { kind, panel };
    } else {
      const panel = new ViewsPanel(
        {
          root: this.uiEl,
          messages,
          views: () => this.config.views ?? [],
          apply: (id) => this.viewAction({ action: "apply", id }),
          reset: () => this.viewAction({ action: "reset" }),
          save: (name, shared, done) =>
            this.transport.push("masu:view", { action: "save", name, shared }, (reply) => done((reply.error as string | undefined) ?? null)),
          remove: (id) => this.transport.push("masu:view", { action: "delete", id }),
          close: () => this.closePanel(true),
        },
        this.viewsButton!,
      );
      this.panel = { kind, panel };
    }
  }

  /** A view applied: its rows from the first. */
  private viewAction(payload: Record<string, unknown>): void {
    this.transport.push("masu:view", payload, (reply) => {
      if (reply.error) {
        this.announce(String(reply.error));
        return;
      }
      this.gridEl.scrollTop = 0;
      this.anchor = null;
      this.active = { row: Math.min(this.active.row, 0), col: Math.min(this.active.col, this.columns.length - 1) };
      this.render();
      this.announceCount();
    });
  }

  private closePanel(focus: boolean): void {
    if (!this.panel) return;
    const { kind, panel } = this.panel;
    this.panel = null;
    panel.destroy();
    if (focus) (kind === "columns" ? this.columnsButton : this.viewsButton)?.focus();
  }

  /** Says once that part of a view no longer applies (Masu.View). */
  private showNotice(): void {
    const notice = this.config.notice;
    if (!notice || notice[0] === this.lastNotice) return;
    this.lastNotice = notice[0];
    this.announce(this.message("view_dropped", { label: notice[1] }));
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
    const editor = this.people.find((person) => person.editing && person.cell && cellKey(person.cell[0], person.cell[1]) === cellKey(row[0], column.key));
    if (editor) {
      this.announce(this.message("peer_editing", { label: editor.name ?? "" }));
      return;
    }

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
    input.style.transform = `translateY(${this.rowTop(cell.row)}px)`;
    input.style.insetInlineStart = `${this.colLeft(cell.col)}px`;
    input.style.width = `${this.widths[cell.col]}px`;
    input.style.height = `${this.config.rowHeight}px`;

    this.editor = { input, row: cell.row, col: cell.col, id: row[0], original: raw, done: false };
    input.addEventListener("keydown", (event) => this.onEditorKey(event));
    input.addEventListener("blur", () => this.commitEdit(null));
    this.body.appendChild(input);
    input.focus();
    if (text === undefined && input.type === "text") input.setSelectionRange(input.value.length, input.value.length);
    this.reportCursor();
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
    // The value the person saw is the one the editor opened with: a save
    // by someone else while they typed is a conflict, not their base.
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value, before: editor.original }]);
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
    this.reportCursor();
  }

  /**
   * Saves values in cells (of rows the browser has): shows them at once,
   * and asks the server to save them; a cell the server refuses shows its
   * old value again, with the error.
   */
  private applyEdits(
    cells: { row: number; col: number; value: string | boolean | null; before?: CellValue }[],
    record = true,
  ): void {
    const edits: Edit[] = [];
    let skipped = 0;
    for (const { row, col, value, before: seen } of cells) {
      const column = this.columns[col];
      const data = this.cache.get(row) ?? this.stale?.get(row);
      if (!column?.editable || !data || this.locked(data, col)) {
        skipped += 1;
        continue;
      }
      const before = seen !== undefined ? seen : rawValue(data[col + 1]);
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

    // Each edit says what the person saw: the server refuses it when the
    // cell changed meanwhile (see Masu.Edit).
    const payload = edits.map((edit) => ({ id: edit.id, key: edit.key, value: edit.value, before: edit.before }));
    this.transport.push("masu:edit", { edits: payload }, (reply) => {
      const errors = (reply.errors as [unknown, string, string, CellValue?][]) ?? [];
      for (const edit of edits) this.saving.delete(cellKey(edit.id, edit.key));
      const refused = new Map<string, { value: CellValue; now: boolean }>();
      for (const [id, key, message, ...now] of errors) {
        const cell = cellKey(id, key);
        // A cell changed meanwhile comes with its value now.
        refused.set(cell, { value: (now[0] ?? null) as CellValue, now: now.length > 0 });
        this.errors.set(cell, message);
      }
      // A refused cell shows its old value (or its value now) until the
      // rows come again.
      for (const edit of edits) {
        const refusal = refused.get(cellKey(edit.id, edit.key));
        if (refusal && edit.row !== undefined && this.valueAt(edit.row, edit.col) !== undefined) {
          const column = this.columns[edit.col];
          const value = refusal.now ? refusal.value : edit.before;
          this.setValue(edit.row, edit.col, column.html ? [escapeHTML(String(value ?? "")), value] : value);
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

  /** Whether the row's state makes its cell of `col` read-only; a group's row is. */
  private locked(data: Row, col: number): boolean {
    if (isGroup(data)) return true;
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

  // The other people who have the grid open (Masu.Presence): a line in
  // their color on the cell they are on, where the row is on this
  // person's screen (their order and filters are their own), with their
  // name; a cell they edit opens no editor here.

  setPeople(people: Person[]): void {
    this.people = people;
    this.drawPeople();
    if (this.following) this.follow();
    else this.markFollowed();
  }

  private drawPeople(): void {
    for (const el of this.peerEls) el.remove();
    this.peerEls = [];
    if (this.people.length === 0) return;

    const rowsById = new Map<string, number>();
    for (const [index, rowEl] of this.rows) {
      const data = rowEl.masuRow;
      if (data) rowsById.set(JSON.stringify(data[0]), index);
    }

    // Their selected ranges: a wash in their color on the cells of their
    // rows, wherever this person's order puts them.
    for (const person of this.people) {
      if (!person.range) continue;
      const cols = person.range.keys.map((key) => this.columns.findIndex((column) => column.key === key)).filter((col) => col >= 0);
      if (cols.length === 0) continue;
      const first = Math.min(...cols);
      const last = Math.max(...cols);
      const left = this.colLeft(first);
      const width = this.colLeft(last) + this.widths[last] - left;
      for (const id of person.range.rows) {
        const index = rowsById.get(JSON.stringify(id));
        if (index === undefined) continue;
        const el = document.createElement("div");
        el.className = "masu-peer-range";
        el.style.setProperty("--masu-peer-color", person.color);
        el.style.transform = `translateY(${this.rowTop(index)}px)`;
        el.style.insetInlineStart = `${left}px`;
        el.style.width = `${width}px`;
        el.style.height = `${this.config.rowHeight}px`;
        el.setAttribute("aria-hidden", "true");
        this.body.appendChild(el);
        this.peerEls.push(el);
      }
    }

    for (const person of this.people) {
      if (!person.cell) continue;
      const index = rowsById.get(JSON.stringify(person.cell[0]));
      const col = this.columns.findIndex((column) => column.key === person.cell![1]);
      if (index === undefined || col < 0) continue;

      const el = document.createElement("div");
      el.className = `masu-peer${person.editing ? " masu-peer-editing" : ""}${index === 0 ? " masu-peer-top" : ""}`;
      el.style.setProperty("--masu-peer-color", person.color);
      el.style.transform = `translateY(${this.rowTop(index)}px)`;
      el.style.insetInlineStart = `${this.colLeft(col)}px`;
      if (this.columns[col].pinned) el.classList.add("masu-peer-pinned");
      el.style.width = `${this.widths[col]}px`;
      el.style.height = `${this.config.rowHeight}px`;
      el.dataset.person = person.id;
      el.setAttribute("aria-hidden", "true");

      const label = document.createElement("span");
      label.className = "masu-peer-label";
      const custom = options.peerLabel?.(person);
      if (custom instanceof HTMLElement) label.appendChild(custom);
      else label.textContent = custom ?? (person.editing ? this.message("peer_typing", { label: person.name ?? "" }) : (person.name ?? ""));
      el.appendChild(label);

      this.body.appendChild(el);
      this.peerEls.push(el);
    }
  }

  /**
   * The selected range as the others can draw it in their own order: the
   * ids of its rows that the browser has (at most 500) and its columns'
   * keys.
   */
  private rangeForOthers(): { rows: unknown[]; keys: string[] } | null {
    const range = this.highlight();
    if (!range || (range.top === range.bottom && range.left === range.right)) return null;
    const rows: unknown[] = [];
    for (let index = range.top; index <= range.bottom && rows.length < 500; index++) {
      const data = this.cache.get(index) ?? this.stale?.get(index);
      if (data) rows.push(data[0]);
    }
    return { rows, keys: this.columns.slice(range.left, range.right + 1).map((column) => column.key) };
  }

  /**
   * Follows a person, or stops following them. The grid shows their view
   * (their order, filters and search, when their grid shares them) and
   * keeps their place in it on the screen; the person's own view is kept
   * aside, and comes back on Stop.
   */
  toggleFollow(id: string): void {
    if (this.following === id) {
      this.stopFollowing(true);
      return;
    }
    this.ownView ??= {
      query: this.query,
      scrollTop: this.gridEl.scrollTop,
      scrollLeft: this.gridEl.scrollLeft,
      active: { ...this.active },
      anchor: this.anchor && { ...this.anchor },
    };
    this.following = id;
    this.refusedView = null;
    this.follow();
  }

  /**
   * Stops following. Stop (`restore`) brings the person's own view back;
   * their own scrolling, clicking or typing keeps the view they see, with
   * "Back to your view" while it is not their own.
   */
  private stopFollowing(restore: boolean): void {
    if (!this.following) return;
    const person = this.followed;
    this.following = null;
    delete this.el.dataset.following;
    this.markFollowed();

    if (restore) this.backToOwnView();
    else if (this.ownView && person && !sameView(this.ownView.query, this.query)) this.showBanner(person, "their_view");
    else {
      this.ownView = null;
      this.removeBanner();
    }
  }

  /** The person made a view of their own: nothing to go back to. */
  private dropFollow(): void {
    this.following = null;
    this.ownView = null;
    delete this.el.dataset.following;
    this.removeBanner();
    this.markFollowed();
  }

  /** The person's own view and place again. */
  private backToOwnView(): void {
    const own = this.ownView;
    this.ownView = null;
    this.removeBanner();
    if (!own) return;
    const place = () => {
      this.gridEl.scrollTop = own.scrollTop;
      this.gridEl.scrollLeft = own.scrollLeft;
      this.active = { row: Math.min(own.active.row, this.total - 1), col: own.active.col };
      this.anchor = own.anchor;
      this.render();
    };
    if (sameView(own.query, this.query)) place();
    else this.setQuery(own.query, "restore", place);
  }

  /** Shows the followed person's view, then their place in it. */
  private follow(): void {
    const person = this.people.find((p) => p.id === this.following);
    if (!person) {
      // They left: the grid keeps what it shows.
      this.stopFollowing(false);
      return;
    }
    this.followed = person;
    this.el.dataset.following = person.id;
    this.el.style.setProperty("--masu-follow-color", person.color);
    this.showBanner(person, "following");
    this.markFollowed();

    const view = person.view;
    if (view && !sameView(view, this.query) && JSON.stringify(view) !== this.refusedView) {
      this.setQuery(view, "follow", () => this.placeFollowed());
      this.announceView(person, view);
    } else if (!this.querying) {
      this.placeFollowed();
    }
  }

  /**
   * Scrolls to the followed person's place: the first row of their screen
   * when the grid shows their view, else their cell, where the server says
   * it is in this person's order.
   */
  private placeFollowed(): void {
    const person = this.people.find((p) => p.id === this.following);
    if (!person) return;
    const shared = person.view !== null && sameView(person.view, this.query);
    const top = shared && person.top !== null && person.top !== undefined ? person.top : null;
    const target = top ?? person.cell?.[0];
    if (target === undefined || target === null) return;
    const col = person.cell ? Math.max(0, this.columns.findIndex((column) => column.key === person.cell![1])) : -1;

    const place = (index: number | null) => {
      if (this.following !== person.id) return;
      if (index === null) {
        this.showBanner(person, "follow_hidden");
        return;
      }
      if (top === null) {
        this.scrollToCell(index, Math.max(col, 0));
        return;
      }
      // Their screen's first row first, then their cell, if this screen
      // is smaller than theirs.
      this.gridEl.scrollTop = this.rowTop(index);
      this.render();
      const cell = person.cell ? this.indexOf(person.cell[0]) : undefined;
      if (cell !== undefined) this.scrollToCell(cell, Math.max(col, 0));
    };

    const index = this.indexOf(target);
    if (index !== undefined) {
      place(index);
      return;
    }
    const revision = this.revision;
    this.transport.push("masu:locate", { id: target }, (reply) => {
      if (reply.revision !== revision) return;
      place((reply.index as number | null | undefined) ?? null);
    });
  }

  /** The index of a row on the screen, by its id. */
  private indexOf(id: unknown): number | undefined {
    const wanted = JSON.stringify(id);
    for (const [index, rowEl] of this.rows) {
      if (rowEl.masuRow && JSON.stringify(rowEl.masuRow[0]) === wanted) return index;
    }
    return undefined;
  }

  private scrollToCell(index: number, col: number): void {
    const rh = this.config.rowHeight;
    const view = this.gridEl.clientHeight - this.head.offsetHeight;
    const top = this.rowTop(index);
    if (top < this.gridEl.scrollTop || top + rh > this.gridEl.scrollTop + view) {
      this.gridEl.scrollTop = Math.max(0, top - (view - rh) / 2);
    }
    this.scrollToColumn(col);
    this.schedule();
  }

  /** Scrolls sideways to show a column, unless it shows: the pinned ones always do. */
  private scrollToColumn(col: number): void {
    const scroll = scrollFor(col, this.widths, this.pinned, Math.abs(this.gridEl.scrollLeft), this.gridEl.clientWidth);
    if (scroll !== null) this.gridEl.scrollLeft = scroll;
  }

  /** Says whose view the grid now shows, with its filters, for a screen reader. */
  private announceView(person: Person, view: QuerySpec): void {
    const messages = this.messages();
    const parts = view.filters.flatMap((filter) => {
      const col = this.columns.findIndex((column) => column.key === filter.key);
      return col < 0 ? [] : [describe(filter, this.columns[col], (value) => this.formatters[col](value as CellValue), messages)];
    });
    if (view.search) parts.push(`"${view.search}"`);
    const text = this.message("showing_view", { label: person.name ?? person.id });
    this.announce(parts.length > 0 ? `${text}: ${parts.join("; ")}` : text);
  }

  /**
   * The banner above the grid: "Following Ada" with Stop, "Ada is on a row
   * your filters leave out", or, once the person took over, "Ada's view"
   * with "Back to your view".
   */
  private showBanner(person: Person, kind: "following" | "follow_hidden" | "their_view"): void {
    if (!this.followEl) {
      this.followEl = document.createElement("div");
      this.followEl.className = "masu-following";
      this.followEl.setAttribute("role", "status");
      this.uiEl.appendChild(this.followEl);
    }
    const name = person.name ?? person.id;
    const words = this.message(kind, { label: name });
    this.followEl.style.setProperty("--masu-follow-color", person.color);
    // Drawn again only when it says something new: a button replaced
    // under the pointer loses its click.
    if (this.followEl.dataset.kind === kind && this.followEl.firstChild?.textContent === words) return;
    this.followEl.dataset.kind = kind;
    const text = document.createElement("span");
    text.textContent = words;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "masu-following-stop";
    if (kind === "their_view") {
      button.textContent = this.message("back_to_view", {});
      button.addEventListener("click", () => this.backToOwnView());
    } else {
      button.textContent = this.message("stop_following", {});
      button.addEventListener("click", () => this.stopFollowing(true));
    }
    this.followEl.replaceChildren(text, button);
  }

  private removeBanner(): void {
    this.followEl?.remove();
    this.followEl = null;
    this.el.style.removeProperty("--masu-follow-color");
  }

  /** The avatar of the person followed is pressed. */
  private markFollowed(): void {
    for (const el of this.el.querySelectorAll<HTMLElement>(":scope > .masu-people .masu-person[data-person]")) {
      el.setAttribute("aria-pressed", el.dataset.person === this.following ? "true" : "false");
    }
  }

  /** Tells the others where this person is, when it changes, at most every 150 ms. */
  private reportCursor(): void {
    if (!this.config.presence || this.cursorTimer) return;
    this.cursorTimer = setTimeout(() => {
      this.cursorTimer = null;
      const data = this.active.row >= 0 ? (this.cache.get(this.active.row) ?? this.stale?.get(this.active.row)) : undefined;
      const cell = data ? [data[0], this.columns[this.active.col].key] : null;
      const range = this.rangeForOthers();
      // The first row on the screen, for those who follow this person.
      const first = this.cache.get(this.firstWholeRow());
      const top = first ? first[0] : null;
      const cursor = JSON.stringify([cell, range, this.editor !== null, top]);
      if (cursor === this.sentCursor) return;
      this.sentCursor = cursor;
      this.transport.push("masu:cursor", { cell, range, editing: this.editor !== null, top });
    }, CURSOR_DELAY);
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
      const top = this.rowTop(cell.row);
      const bottom = top + rh;
      const viewTop = this.gridEl.scrollTop;
      const viewBottom = viewTop + this.gridEl.clientHeight - headHeight;
      if (top < viewTop) this.gridEl.scrollTop = top;
      else if (bottom > viewBottom) this.gridEl.scrollTop = bottom - (this.gridEl.clientHeight - headHeight);
    }
    this.scrollToColumn(cell.col);
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

/** A group's row (Masu.Group): its id is its path, `["masu-group", key, value, ...]`. */
function isGroup(row: Row): boolean {
  const id = row[0];
  return Array.isArray(id) && id[0] === "masu-group";
}

/** Sets a style property when it changes: the patch watcher hears every set. */
function setStyle(el: HTMLElement, name: string, value: string): void {
  if (el.style.getPropertyValue(name) !== value) el.style.setProperty(name, value);
}

function setAttribute(el: HTMLElement, name: string, value: string): void {
  if (el.getAttribute(name) !== value) el.setAttribute(name, value);
}

function keysOf(columns: ColumnConfig[]): string {
  return columns.map((column) => column.key).join("\u0000");
}

function withoutWidths(columns: ColumnConfig[]): Omit<ColumnConfig, "width">[] {
  return columns.map(({ width: _width, ...column }) => column);
}

function toolbarButton(label: string, className: string, icon: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `masu-toolbar-button ${className}`;
  button.setAttribute("aria-haspopup", "dialog");
  button.setAttribute("aria-expanded", "false");
  button.innerHTML = icon;
  const text = document.createElement("span");
  text.className = "masu-toolbar-text";
  text.textContent = label;
  button.appendChild(text);
  return button;
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
  peer_editing: "{label} is editing this cell",
  peer_typing: "{label} is typing",
  following: "Following {label}",
  follow_hidden: "{label} is on a row your filters leave out",
  stop_following: "Stop",
  showing_view: "Showing {label}'s view",
  their_view: "{label}'s view",
  back_to_view: "Back to your view",
  columns_menu: "Columns",
  columns_search: "Find a column",
  show_all: "Show all",
  pin: "Pin {label}",
  pin_none: "Not pinned",
  pin_start: "Pinned to the start",
  pin_end: "Pinned to the end",
  move_up: "Move {label} up",
  move_down: "Move {label} down",
  moved: "{label} moved",
  views_menu: "Views",
  views_current: "Views: {label}",
  detail_shown: "Details shown",
  group_by: "Group by {label}",
  ungroup_by: "Stop grouping by {label}",
  grouped_by: "Grouped by {label}",
  totals: "Total",
  detail_hidden: "Details hidden",
  view_reset: "The grid's own view",
  view_name: "Name this view",
  view_share: "Share with everyone",
  view_save: "Save view",
  view_saved: "View saved",
  view_shared: "Shared",
  view_delete: "Delete {label}",
  view_dropped: "Part of this view no longer applies: {label}",
};

// Three columns, and a stack of sheets, drawn for Masu.
const COLUMNS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><rect x="2" y="2.5" width="12" height="11" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 2.5v11M10 2.5v11" stroke="currentColor" stroke-width="1.4"/></svg>';
const VIEWS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 5.5 8 2.5l5.5 3L8 8.5z M2.5 8.5 8 11.5l5.5-3 M2.5 11 8 14l5.5-3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>';

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

interface OwnView {
  query: QuerySpec;
  scrollTop: number;
  scrollLeft: number;
  active: Cell;
  anchor: Cell | null;
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
