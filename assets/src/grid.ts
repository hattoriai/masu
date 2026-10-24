// The grid in the browser. The server renders its structure and first
// rows (Masu.Grid); the grid takes them over and from then on draws only
// the rows on the screen, a few more on each side, reusing their
// elements as the person scrolls. The rows it lacks it asks the server
// for, a block at a time (BlockCache), once the scrolling pauses.
//
// Focus stays on the grid element; the active cell is its
// aria-activedescendant, so that a screen reader follows it while the
// rows come and go.
//
// This is the grid's core: its rows, their drawing and scrolling, the
// query and the events. Each feature is a class of its own in features/,
// with its state, made with the grid (`this.editing`, `this.peers`, ...):
// it reaches the core through `this.grid`, and the core reaches it
// through its property. The pure parts (geometry, offsets, scroll, the
// filters' words) are functions of their own modules, tested alone.

import { BlockCache } from "./blocks";
import { cacheFor, keysOf, readConfig, withoutWidths } from "./config";
import { scrollParent, setAttribute, setStyle } from "./dom";
import { Actions } from "./features/actions";
import { RowActivation } from "./features/activation";
import { Clipboard } from "./features/clipboard";
import { Deleting } from "./features/deleting";
import { Details } from "./features/details";
import { Editing } from "./features/editing";
import { Filters } from "./features/filters";
import { History } from "./features/history";
import { Keyboard } from "./features/keyboard";
import { ColumnLayout } from "./features/layout";
import { NewRows } from "./features/new-rows";
import { Peers } from "./features/peers";
import { Pointer } from "./features/pointer";
import { RowSelection } from "./features/selection";
import { Toolbar } from "./features/toolbar";
import { activeIn } from "./following";
import { formatter, manyFormatter, type Formatter } from "./format";
import { contains, rect, visibleRows, type Cell, type Rect } from "./geometry";
import { headerCell, MORE_ICON } from "./header";
import { fill, pins, scrollFor, visualLeft, type Pins } from "./layout";
import { FLASH, OVERSCAN } from "./limits";
import { DEFAULT_MESSAGES, type MessageValues } from "./messages";
import { indexAt, rowTop, totalHeight, type Gap } from "./offsets";
import { cellKey, isDraft, isGroup } from "./rows";
import { boxHeight, clamp, toContent, toScroll, wheelPixels } from "./scroll";
import { nextSorts } from "./sorting";
import type { Draft, Later, RowElement, TreeNode } from "./records";
import type { BlockReply, CellValue, ColumnConfig, Config, QuerySpec, Row, Transport } from "./types";

/** The rows more than it knows that a grid without a count scrolls over: a block. */
const GROW = 100;
const PREFETCH = 60;
const REQUEST_DELAY = 40;
const SEARCH_DELAY = 250;
/** The width of the cell at the end of each row with its row actions' button. */
const ROW_ACTIONS_WIDTH = 40;

export class Grid {
  readonly el: HTMLElement;
  readonly id: string;
  transport: Transport;
  config: Config;
  columns: ColumnConfig[];
  /** The widths the columns are given: the server's, or the person's. */
  sizes: number[];
  /** The widths the columns are drawn at: their sizes, and the room the columns leave to those that grow. */
  widths: number[];
  /** The width of the box the columns were laid out in. */
  private room = 0;
  formatters: Formatter[] = [];
  private aggregateFormatters: Formatter[] = [];
  /** The row of totals (Masu.Group). */
  private footEl: HTMLElement | null = null;
  total: number;
  /** The count is the query's; else the rows read, and maybe more. */
  exact = true;
  /** The count was asked for (`masu:count`) in this revision. */
  countAsked = false;
  revision: number;
  query: QuerySpec;
  cache: BlockCache;
  /** The rows of the revision before, shown until the new ones come. */
  stale: BlockCache | null = null;
  /** The rows on the screen are old: ask for them at once, not after a pause. */
  private urgent = false;
  /** The part of the grid the browser owns (phx-update="ignore"): menus go in it, out of the server's renders. */
  uiEl: HTMLElement;
  /** The scroll box: the server's, for the details it renders in it. */
  gridEl: HTMLElement;
  /** The header and the rows: the browser's (phx-update="ignore"). */
  private contentEl: HTMLElement;
  patchObserver: MutationObserver | null = null;
  head: HTMLElement;
  headerRow: HTMLElement;
  body: HTMLElement;
  private emptyEl: HTMLElement | null;
  private statusEl: HTMLElement | null;
  private searchEl: HTMLInputElement | null;
  /** When a menu opened by its key: the browser follows the key with a contextmenu event, on the menu. */
  menuKeyAt = 0;
  /** Where the pinned columns stick. */
  private pinned: Pins = pins([], []);
  /** A block of a revision the grid does not have yet (a layout's answer). */
  private pendingBlock: BlockReply | null = null;
  private lastNotice = 0;
  rows = new Map<number, RowElement>();
  private pool: RowElement[] = [];
  active: Cell = { row: 0, col: 0 };
  anchor: Cell | null = null;
  dragging = false;
  private frame: number | null = null;
  /** The height of the rows, and the place of the screen's top in them (see scroll.ts). */
  private contentHeight = 0;
  private content = 0;
  /** The scrollTop the grid set last, in a grid taller than a browser draws. */
  private wrote: number | null = null;
  private queries = 0;
  /** The writes and actions that go on later (Masu.Write.async/1, `:async`), by their token. */
  later = new Map<string, Later>();
  /** The rows that changed (Masu.Live), each until its flash ends. */
  flash = new Map<string, { until: number; color: string | undefined }>();
  /** A query is on its way to the server. */
  querying = false;
  /** A query whose rows come later (`load={:async}`, `on_query`): what to do when they come. */
  private pendingQuery: { origin: "self" | "follow" | "restore"; then?: () => void } | null = null;
  /** The blocks asked for whose rows come in a `masu:block` event, by their first row. */
  private blockWaiters = new Map<number, (answer: BlockReply) => void>();
  /** What waits for a count that comes with the server's render. */
  private countWaiter: (() => void) | null = null;
  /** The next revision's rows are not the old ones moved (a tree's row opened): drop the old. */
  private freshRows = false;
  private requestTimer: ReturnType<typeof setTimeout> | null = null;
  private searchTimer: ReturnType<typeof setTimeout> | null = null;
  private observer: ResizeObserver | null = null;
  private cleanups: (() => void)[] = [];

  // Its features, each with its state (features/).

  readonly editing = new Editing(this);
  readonly newRows = new NewRows(this);
  readonly deleting = new Deleting(this);
  readonly actions = new Actions(this);
  readonly history = new History(this);
  readonly filters = new Filters(this);
  readonly toolbar = new Toolbar(this);
  readonly details = new Details(this);
  readonly activation = new RowActivation(this);
  readonly clipboard = new Clipboard(this);
  readonly peers = new Peers(this);
  readonly rowSelection = new RowSelection(this);
  readonly layout = new ColumnLayout(this);
  readonly keyboard = new Keyboard(this);
  readonly pointer = new Pointer(this);

  // The grid's life: made from the server's render, updated by the next
  // ones, and destroyed with its element.

  constructor(el: HTMLElement, transport: Transport) {
    this.el = el;
    this.id = el.id;
    // Issho's pointers, through the symbols it reads (no import of it): an
    // agent at work in the grid is drawn at its cell (`locate`), and a
    // person's pointer over a cell is that cell (`point`), drawn on it on
    // each screen, whatever the order or the scroll there.
    const locator = (at: unknown) => this.peers.locate(at);
    const pointer = (x: number, y: number) => this.peers.cellUnder(x, y);
    const element = el as unknown as Record<symbol, unknown>;
    element[Symbol.for("issho.locator")] = locator;
    element[Symbol.for("issho.point")] = pointer;
    this.cleanups.push(() => {
      if (element[Symbol.for("issho.locator")] === locator) delete element[Symbol.for("issho.locator")];
      if (element[Symbol.for("issho.point")] === pointer) delete element[Symbol.for("issho.point")];
    });
    this.transport = transport;
    this.config = readConfig(el);
    this.columns = this.config.columns;
    this.sizes = this.columns.map((column) => column.width);
    this.widths = this.sizes.slice();
    this.total = this.config.total;
    this.exact = this.config.exact !== false;
    this.revision = this.config.revision;
    this.query = this.config.query;
    this.cache = cacheFor(this.config);

    // Only this grid's own elements: a detail may hold another grid.
    this.gridEl = el.querySelector<HTMLElement>(":scope > .masu-grid")!;
    this.uiEl = el.querySelector<HTMLElement>(":scope > .masu-ui") ?? el;
    this.contentEl = this.gridEl.querySelector<HTMLElement>(":scope > .masu-content") ?? this.gridEl;
    this.details.detailsEl = this.gridEl.querySelector<HTMLElement>(":scope > .masu-details");
    this.head = this.contentEl.querySelector<HTMLElement>(":scope > .masu-head")!;
    this.headerRow = this.head.querySelector<HTMLElement>(".masu-header")!;
    this.body = this.contentEl.querySelector<HTMLElement>(":scope > .masu-body")!;
    this.emptyEl = this.contentEl.querySelector<HTMLElement>(":scope > .masu-empty");
    this.statusEl = el.querySelector<HTMLElement>(":scope > .masu-status");
    this.searchEl = this.uiEl.querySelector<HTMLInputElement>(".masu-search");

    // The chips of the filters, above the grid, in the browser's part.
    this.uiEl.appendChild(this.filters.chipsEl);

    this.makeFormatters();
    if (this.config.initial) this.cache.store(this.config.initial.from, this.config.initial.rows);

    this.renderHeader();
    this.applyWidths();
    this.body.replaceChildren();
    this.rowSelection.readSelection();
    this.toolbar.renderToolbar();
    this.renderTotals();
    this.listen();
    this.watchPatches();
    this.render();
    this.showNotice();
  }

  /** The server rendered the grid again: new rows, columns or options. */
  update(): void {
    this.peers.markFollowed();
    const config = readConfig(this.el);
    const previous = this.config;
    // The columns that show, in their order: the rows of others are of no use.
    const keysChanged = keysOf(config.columns) !== keysOf(previous.columns);
    const columnsChanged =
      JSON.stringify(withoutWidths(config.columns)) !== JSON.stringify(withoutWidths(previous.columns)) ||
      (config.rowActions?.length ?? 0) > 0 !== (previous.rowActions?.length ?? 0) > 0;
    const widthsChanged = JSON.stringify(config.columns.map((c) => [c.key, c.width])) !== JSON.stringify(previous.columns.map((c) => [c.key, c.width]));
    this.config = config;
    if ((config.filterBar !== false) !== (previous.filterBar !== false) || (config.headerFilters !== false) !== (previous.headerFilters !== false)) {
      this.renderHeader();
    }

    if (columnsChanged || (widthsChanged && !this.layout.resizing)) {
      // Widths the server sends (a view applied) win; else the person's stay.
      const sizes = new Map(this.columns.map((column, i) => [column.key, this.sizes[i]]));
      const sent = new Map(previous.columns.map((column) => [column.key, column.width]));
      this.columns = config.columns;
      this.sizes = this.columns.map((column) =>
        widthsChanged && sent.get(column.key) !== column.width ? column.width : (sizes.get(column.key) ?? column.width),
      );
      this.makeFormatters();
      for (const draft of this.newRows.drafts) draft.row = this.newRows.draftRow(draft);
      this.renderHeader();
      this.applyWidths();
      this.clearRows();
      this.pool = [];
    }
    if (keysChanged) {
      this.cache = cacheFor(config);
      this.stale = null;
      this.active = { row: this.active.row, col: Math.min(this.active.col, this.columns.length - 1) };
    }
    // A view applied by the server (a saved view, the URL) brings its
    // search; not over a search the person is typing.
    const search = config.query.search ?? "";
    if (this.searchEl && !this.searchTimer && search !== (previous.query.search ?? "") && search !== this.searchEl.value.trim()) {
      this.searchEl.value = search;
    }
    if (this.rowSelection.readSelection()) {
      this.renderHeader();
      this.refreshRows();
    }
    this.toolbar.renderToolbar();
    this.renderTotals();
    this.showNotice();
    this.details.measureDetails();
    this.actions.placeActionPanel();
    this.editing.placeFormEditor();

    // A count that came in (count={:deferred}), with the same rows.
    if (config.revision === this.revision && (config.total !== this.total || (config.exact !== false) !== this.exact)) {
      this.setTotal(config.total, config.exact !== false);
    }
    // Another page (the pager): its rows, from its top.
    if (this.paged() && config.page !== previous.page) {
      this.scrollToContent(0);
      this.active = { row: this.active.row < 0 ? -1 : this.base(), col: this.active.col };
      this.anchor = null;
      this.clearRows();
      this.urgent = true;
    }

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
      this.countAsked = false;
      this.blockWaiters.clear();
      this.setTotal(config.total, config.exact !== false);
      this.query = config.query;
      this.finishQuery(true);
      // The rows of the older revision stay on the screen until the new
      // ones come, so that the grid does not blink as its rows change;
      // not when the columns moved.
      this.stale = keysChanged || this.freshRows ? null : this.cache;
      this.freshRows = false;
      this.cache = cacheFor(config);
      if (config.initial) this.cache.store(config.initial.from, config.initial.rows);
      if (this.pendingBlock?.revision === this.revision) this.cache.store(this.pendingBlock.from, this.pendingBlock.rows);
      this.pendingBlock = null;
      this.renderHeader();
      this.urgent = true;
    }

    // A read that stopped, or failed, with no new rows: the query is the
    // server's still.
    if (this.pendingQuery && !config.running && config.revision === this.revision) {
      this.query = config.query;
      this.renderHeader();
      this.finishQuery(false);
    }
    if (this.countWaiter && this.exact) {
      const then = this.countWaiter;
      this.countWaiter = null;
      then();
    }
    this.showBusy();

    this.render();
  }

  /** Rows that come later: the grid looks busy while they run. */
  private showBusy(): void {
    this.el.classList.toggle("masu-busy", this.querying || this.config.running === true);
  }

  /** The rows of a query that came later (`fresh`), or none (it stopped). */
  private finishQuery(fresh: boolean): void {
    const pending = this.pendingQuery;
    if (!pending) return;
    this.pendingQuery = null;
    this.querying = false;
    if (fresh) {
      this.scrollToContent(0);
      this.active = { row: Math.min(Math.max(this.active.row, -1), this.total - 1), col: this.active.col };
      this.anchor = null;
      if (pending.origin === "self") this.announceCount();
      pending.then?.();
    }
  }

  /** A block of rows read in a task, which the server sends when it has it. */
  receiveBlock(answer: BlockReply): void {
    const waiter = this.blockWaiters.get(answer.from);
    if (waiter) {
      this.blockWaiters.delete(answer.from);
      waiter(answer);
    } else {
      this.takeBlock(answer);
    }
  }

  destroy(): void {
    this.filters.closeMenu(false);
    this.actions.closeCellMenu(false);
    this.toolbar.closePanel(false);
    this.details.detailObserver?.disconnect();
    this.patchObserver?.disconnect();
    this.editing.editor?.el.remove();
    this.editing.editor = null;
    this.actions.unfollowPanel();
    for (const cleanup of this.cleanups) cleanup();
    this.cleanups = [];
    this.observer?.disconnect();
    if (this.frame !== null) cancelAnimationFrame(this.frame);
    if (this.requestTimer) clearTimeout(this.requestTimer);
    if (this.searchTimer) clearTimeout(this.searchTimer);
    if (this.peers.cursorTimer) clearTimeout(this.peers.cursorTimer);
  }

  // The query: a new order, filters or search, applied by the server.

  /**
   * Applies a view: the person's own (`self`), that of the person they
   * follow (`follow`), or their own again (`restore`). `then` runs once the
   * rows of the new view came.
   */
  setQuery(query: QuerySpec, origin: "self" | "follow" | "restore" = "self", then?: () => void): void {
    // A view of the person's own ends following, and the view kept aside.
    if (origin === "self") this.peers.dropFollow();
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
      // Its rows come with the server's render (a new revision).
      if (answer.pending && !answer.error) {
        this.querying = true;
        this.pendingQuery = { origin, then };
        this.showBusy();
        return;
      }
      if (answer.error) {
        if (origin === "follow") this.peers.refusedView = JSON.stringify(query);
        this.query = previous;
        if (origin !== "self" && this.searchEl) this.searchEl.value = previous.search ?? "";
        this.renderHeader();
        this.announce(answer.error);
        return;
      }
      this.revision = answer.revision;
      this.countAsked = false;
      this.setTotal(answer.total, answer.exact !== false);
      this.query = answer.query ?? query;
      this.cache.clear();
      this.stale = null;
      this.cache.store(answer.from, answer.rows);
      this.scrollToContent(0);
      this.active = { row: Math.min(Math.max(this.active.row, -1), this.total - 1), col: this.active.col };
      this.anchor = null;
      this.renderHeader();
      this.clearRows();
      this.render();
      if (origin === "self") this.announceCount();
      then?.();
    });
  }

  // Rendering: the rows on the screen, drawn in a frame, their elements
  // reused as the person scrolls.

  private schedule(): void {
    if (this.frame !== null) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.render();
    });
  }

  render(): void {
    const rh = this.config.rowHeight;
    // The rows the body holds: every row, or a page's (`paging`).
    const base = this.base();
    const count = this.end() - base;
    const gaps = this.localGaps();
    this.contentHeight = totalHeight(count, rh, gaps);
    setStyle(this.body, "height", `${boxHeight(this.contentHeight)}px`);
    this.fitHeight();
    if (!this.scaled()) this.content = this.gridEl.scrollTop;
    const y = this.contentTop();
    // Where the rows are drawn: their place in the content, less the
    // content above the scroll box's top (none in most grids).
    const shift = y - this.gridEl.scrollTop;
    // -1 while the count is not known (ARIA).
    setAttribute(this.gridEl, "aria-rowcount", this.exact ? String(this.rowCount() + 1) : "-1");
    setAttribute(this.gridEl, "aria-colcount", String(this.columns.length + (this.hasRowActions() ? 1 : 0)));
    if (this.emptyEl) this.emptyEl.hidden = this.total > 0 || this.newRows.drafts.length > 0;
    this.newRows.leaveDraft();

    const headHeight = this.head.offsetHeight;
    const local =
      gaps.length === 0
        ? visibleRows(y, this.gridEl.clientHeight - headHeight, rh, count, OVERSCAN)
        : {
            first: Math.max(0, indexAt(y, rh, gaps) - OVERSCAN),
            last: Math.min(count - 1, indexAt(y + this.gridEl.clientHeight - headHeight, rh, gaps) + OVERSCAN),
          };
    const first = local.first + base;
    const last = local.last + base;

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
      const top = this.rowTop(index) - shift;
      if (rowEl.masuTop !== top) {
        rowEl.masuTop = top;
        rowEl.style.transform = `translateY(${top}px)`;
      }
      if (index === this.addIndex()) this.newRows.fillAddRow(rowEl, index);
      else this.fillRow(rowEl, index, this.dataAt(index) ?? null);
      this.markRow(rowEl, index, selection);
    }

    this.markHeader(selection);
    this.updateActiveDescendant();
    if (this.editing.editor) this.editing.editor.el.style.insetInlineStart = `${this.colLeft(this.editing.editor.col)}px`;
    this.details.placeDetails(headHeight);
    this.peers.drawPeople();
    this.peers.reportCursor();
    this.cache.evict(this.cache.blockOf(first));
    // A page reads its own rows, and no other page's.
    this.planRequests(first, Math.min(last, this.span() - 1), this.paged() ? [base, this.end() - 1] : null);
    // At the end of the rows it knows, a grid that does not know its
    // count asks for it, once.
    if (!this.exact && !this.paged() && count > 0 && local.last >= this.span() - 1) this.askCount();
  }

  clearRows(): void {
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
    if (this.hasRowActions()) rowEl.appendChild(this.makeRowActionsCell());
    return rowEl;
  }

  /** The cell at the end of a row, with the button of its row actions' menu: it sticks to the end. */
  private makeRowActionsCell(): HTMLDivElement {
    const cell = document.createElement("div");
    cell.className = `masu-row-actions ${this.rowActionsPin()}`;
    cell.setAttribute("role", "gridcell");
    cell.setAttribute("aria-colindex", String(this.columns.length + 1));
    const button = document.createElement("button");
    button.type = "button";
    button.className = "masu-row-actions-button";
    button.tabIndex = -1;
    button.setAttribute("aria-label", this.message("row_actions", {}));
    button.setAttribute("aria-haspopup", "menu");
    button.innerHTML = MORE_ICON;
    cell.appendChild(button);
    return cell;
  }

  /** The row actions' cells stick to the end, as the columns pinned there; the first pinned to the end draws the edge. */
  private rowActionsPin(): string {
    const edge = this.columns[this.columns.length - 1]?.pinned !== "end";
    return `masu-pinned masu-pinned-end${edge ? " masu-pinned-edge" : ""}`;
  }

  private hasRowActions(): boolean {
    return (this.config.rowActions?.length ?? 0) > 0;
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
  colLeft(col: number): number {
    return visualLeft(col, this.widths, this.pinned, Math.abs(this.gridEl.scrollLeft), this.gridEl.clientWidth);
  }

  private fillRow(rowEl: RowElement, index: number, row: Row | null): void {
    if (rowEl.masuRow === row && rowEl.masuIndex === index && rowEl.dataset.index === String(index)) return;
    rowEl.masuRow = row;
    rowEl.dataset.index = String(index);
    rowEl.classList.toggle("masu-loading", row === null);
    rowEl.setAttribute("aria-busy", row === null ? "true" : "false");

    rowEl.classList.toggle("masu-group-row", row !== null && isGroup(row));
    // Every second row, by its place (CSS's :nth-child(even)): elements are reused.
    rowEl.classList.toggle("masu-row-even", index % 2 === 1);
    rowEl.classList.remove("masu-add-row");
    const draft = row !== null && isDraft(row);
    rowEl.classList.toggle("masu-draft", draft);
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
      } else if (column.html && !draft) {
        const value = row[col + 1] as unknown;
        cell.innerHTML = (Array.isArray(value) ? (value[0] as string) : (value as string | null)) ?? "";
      } else {
        const value = row[col + 1] as CellValue;
        cell.textContent = this.formatters[col](value);
        cell.classList.toggle("masu-null", value === null || (Array.isArray(value) && value.length === 0));
      }
      if (col === 0) this.decorateFirstCell(cell, row);

      const key = row === null ? "" : cellKey(row[0], column.key);
      const error = row === null ? undefined : this.editing.errors.get(key);
      cell.classList.toggle("masu-invalid", error !== undefined);
      cell.classList.toggle("masu-saving", row !== null && this.editing.saving.has(key));
      const edits = draft ? column.creatable === true : column.editable === true;
      const locked = row !== null && edits && this.editing.locked(row, col);
      cell.classList.toggle("masu-editable", edits && !locked);
      cell.classList.toggle("masu-locked", locked);
      if (edits) cell.setAttribute("aria-readonly", locked ? "true" : "false");
      else if (draft) cell.setAttribute("aria-readonly", "true");
      if (error !== undefined) {
        cell.title = error;
        cell.setAttribute("aria-invalid", "true");
      } else {
        cell.removeAttribute("title");
        cell.removeAttribute("aria-invalid");
      }
    });

    if (this.hasRowActions()) {
      const actions = cells[this.columns.length] as HTMLElement | undefined;
      if (actions) {
        actions.id = `${this.id}-r${index}-actions`;
        const button = actions.firstElementChild as HTMLElement | null;
        if (button) button.hidden = row === null || this.rowActionsOf(row).length === 0;
      }
    }

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

  /** Where a row's own state starts: after its id, its cells and its read-only cells. */
  private afterCells(): number {
    return this.columns.length + 1 + (this.config.locks ? 1 : 0);
  }

  /** The row actions a row shows: `[id, disabled, href]` of each (Masu.Action). */
  rowActionsOf(row: Row): [number, boolean, string | null][] {
    if (!this.hasRowActions() || isGroup(row) || isDraft(row)) return [];
    const own = (row as unknown[])[this.afterCells()];
    return Array.isArray(own) ? (own as [number, boolean, string | null][]) : [];
  }

  /** The place in the tree of a row (Masu.Tree), after its cells, its read-only cells and its row actions. */
  nodeOf(row: Row): TreeNode | null {
    if (!this.config.tree) return null;
    const meta = (row as unknown[])[this.afterCells() + (this.hasRowActions() ? 1 : 0)];
    if (!Array.isArray(meta)) return null;
    const [level, children, expanded, position, size] = meta as [number, boolean, boolean, number, number];
    return { level, children, expanded, position, size };
  }

  /** The first cell of a row: its indent and arrow in a tree, the arrow of its detail, its box. */
  private decorateFirstCell(cell: HTMLElement, row: Row | null): void {
    // The indent goes too when the grid stops being a tree (no longer
    // grouped): its rows' elements are reused.
    const node = row === null ? null : this.nodeOf(row);
    cell.classList.toggle("masu-tree-cell", node !== null);
    if (node) cell.style.setProperty("--masu-level", String(node.level));
    else cell.style.removeProperty("--masu-level");
    if (row === null || (!this.config.tree && !this.config.detail && !this.config.selection)) return;

    if (node && isGroup(row)) {
      // A group's label: its column, its value, how many rows.
      const meta = (row as unknown[])[this.afterCells() + 1 + (this.hasRowActions() ? 1 : 0)] as [string, CellValue, number];
      const [key, value, count] = meta;
      const column = this.filters.catalogColumn(key);
      const label = document.createElement("span");
      label.className = "masu-group-label";
      const shown = column ? formatter(column.type, this.config.locale ?? undefined, null, column.raw)(value) : String(value);
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
      toggle.dataset.open = String(this.details.openDetails().has(JSON.stringify(row[0])));
      cell.prepend(toggle);
    }
    if (node) {
      const twisty = document.createElement("span");
      twisty.className = "masu-twisty";
      twisty.setAttribute("aria-hidden", "true");
      twisty.dataset.state = node.children ? (node.expanded ? "open" : "closed") : "leaf";
      cell.prepend(twisty);
    }
    if (this.config.selection && !isGroup(row) && !isDraft(row)) {
      const box = document.createElement("input");
      box.type = "checkbox";
      box.className = "masu-select";
      box.tabIndex = -1;
      box.checked = this.rowSelection.isChosen(row[0]);
      box.setAttribute("aria-label", this.message("select_row", {}));
      cell.prepend(box);
    }
    cell.parentElement?.classList.toggle("masu-row-chosen", this.config.selection !== null && !isGroup(row) && this.rowSelection.isChosen(row[0]));
  }

  // Where the rows are: their tops, with the gaps of open details.

  /** The top of a row, under the details open above it. */
  rowTop(index: number): number {
    return rowTop(index - this.base(), this.config.rowHeight, this.localGaps());
  }

  /** Where a row is drawn in the scroll box: its top, less the content above the box's top. */
  rowY(index: number): number {
    return this.rowTop(index) - (this.contentTop() - this.gridEl.scrollTop);
  }

  /** The row at the top of the screen. */
  indexAtTop(): number {
    return indexAt(this.contentTop(), this.config.rowHeight, this.localGaps()) + this.base();
  }

  /** The first row the screen shows whole: where one who follows this person starts. */
  firstWholeRow(): number {
    const index = this.indexAtTop();
    return this.rowTop(index) < this.contentTop() ? index + 1 : index;
  }

  // Scrolling. A grid taller than a browser draws (see scroll.ts): its
  // scroll box stands for its rows in proportion. A grid of the height of
  // its rows (in a document), and one whose page scrolls (`wheel={:page}`).

  private scaled(): boolean {
    return this.contentHeight > boxHeight(this.contentHeight);
  }

  /** The place of the screen's top in the rows: the scrollTop, in a grid of a height a browser draws. */
  contentTop(): number {
    return this.scaled() ? this.content : this.gridEl.scrollTop;
  }

  /** Scrolls to a place in the rows. */
  scrollToContent(top: number): void {
    if (!this.scaled()) {
      this.gridEl.scrollTop = top;
      return;
    }
    const { maxScroll, maxContent } = this.scrollRange();
    this.content = clamp(top, 0, maxContent);
    this.gridEl.scrollTop = toScroll(this.content, maxScroll, maxContent);
    this.wrote = this.gridEl.scrollTop;
    this.schedule();
  }

  private scrollRange(): { maxScroll: number; maxContent: number } {
    const maxScroll = Math.max(0, this.gridEl.scrollHeight - this.gridEl.clientHeight);
    return { maxScroll, maxContent: maxScroll + this.contentHeight - boxHeight(this.contentHeight) };
  }

  /** The scrollbar moved: by the grid, which knows its place, or by the person, in proportion. */
  private onScroll(): void {
    if (this.scaled() && (this.wrote === null || Math.abs(this.gridEl.scrollTop - this.wrote) > 1)) {
      const { maxScroll, maxContent } = this.scrollRange();
      this.content = toContent(this.gridEl.scrollTop, maxScroll, maxContent);
      this.wrote = null;
    }
    this.schedule();
  }

  // A grid of the height of its rows (in a document): its header, its rows
  // (three at least, for an empty grid's message), its edges and a
  // scrollbar across, up to the most it takes; past it, the rows scroll.
  private fitHeight(): void {
    const most = this.config.autoHeight;
    if (!most) return;
    const rows = Math.max(this.contentHeight, 3 * this.config.rowHeight);
    const edges = this.gridEl.offsetHeight - this.gridEl.clientHeight;
    setStyle(this.gridEl, "height", `min(${most}, ${Math.ceil(this.head.offsetHeight + rows + edges)}px)`);
  }

  // A grid in a page that scrolls (`wheel={:page}`): the wheel is the
  // page's until the person is in the grid (a click on it, the keyboard).
  private wheelToPage(event: WheelEvent): boolean {
    if (this.config.wheel !== "page" || event.ctrlKey || event.shiftKey) return false;
    if (this.el.contains(document.activeElement)) return false;
    const target = scrollParent(this.el);
    const step = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? target.clientHeight : 1;
    event.preventDefault();
    target.scrollBy({ top: event.deltaY * step, left: 0 });
    return true;
  }

  /** A wheel moves a tall grid by its own pixels; at an end, it scrolls the page. */
  private onWheel(event: WheelEvent): void {
    if (this.wheelToPage(event)) return;
    if (!this.scaled() || event.ctrlKey || event.shiftKey || event.deltaY === 0) return;
    const view = this.gridEl.clientHeight - this.head.offsetHeight;
    const { maxContent } = this.scrollRange();
    const next = clamp(this.content + wheelPixels(event.deltaY, event.deltaMode, this.config.rowHeight, view), 0, maxContent);
    if (next === this.content) return;
    event.preventDefault();
    if (event.deltaX) {
      this.gridEl.scrollLeft += wheelPixels(event.deltaX, event.deltaMode, this.config.rowHeight, this.gridEl.clientWidth);
    }
    this.scrollToContent(next);
  }

  // The header, the marks of the rows (a tree's nodes, a flash, the active
  // cell), the widths of the columns and the row of totals.

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
      if (records.some((record) => record.target !== this.gridEl)) this.details.measureDetails();
      this.details.placeDetails(this.head.offsetHeight);
    });
    this.patchObserver.observe(this.gridEl, { attributes: true, attributeFilter: ["aria-activedescendant"] });
    if (this.details.detailsEl) this.patchObserver.observe(this.details.detailsEl, { childList: true, attributes: true, subtree: false });
    this.details.observeDetailStyles();
  }

  /** Opens or closes a row of the tree, or every row beside it (`*`). */
  toggleNode(index: number, open: boolean, siblings = false): void {
    const row = this.dataAt(index);
    if (!row) return;
    // The rows under it move: the old ones are of no use.
    this.freshRows = true;
    const from = Math.max(0, this.indexAtTop() - OVERSCAN);
    this.transport.push("masu:toggle", { id: row[0], open, siblings, from }, (reply) => {
      const answer = reply as unknown as BlockReply | null;
      if (answer?.rows) this.takeBlock(answer);
    });
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

  renderHeader(): void {
    const bar = this.filters.filterBar();
    const several = this.query.sorts.length > 1;
    const cells = this.columns.map((column, col) => {
      const position = this.query.sorts.findIndex((sort) => sort.key === column.key);
      const filtered = this.query.filters.some((filter) => filter.key === column.key);
      const menu = this.filters.hasHeaderMenu(col);
      const cell = headerCell({
        id: `${this.id}-h${col}`,
        col,
        column,
        sort: column.sortable && position >= 0 ? { dir: this.query.sorts[position].dir, rank: several ? position + 1 : null } : null,
        selectAll:
          col === 0 && this.config.selection
            ? {
                checked: this.rowSelection.chosen.all && this.rowSelection.chosen.except.size === 0,
                indeterminate: !(this.rowSelection.chosen.all && this.rowSelection.chosen.except.size === 0) && (this.rowSelection.chosen.all || this.rowSelection.chosen.ids.size > 0),
                label: this.message("select_all", {}),
              }
            : null,
        // With the filter bar, the menu of every column is three dots (its
        // chip says it is filtered); without it, the funnel.
        menu: menu
          ? {
              label: this.message(column.filterable && !bar && this.config.headerFilters !== false ? "filter" : "column_menu", {
                label: column.label,
              }),
              expanded: this.filters.menu?.col === col && !this.filters.menu.from,
              icon: column.filterable && !bar && this.config.headerFilters !== false ? "filter" : "more",
              active: filtered && !bar,
            }
          : null,
      });
      this.pin(cell, col);
      return cell;
    });
    if (this.hasRowActions()) {
      const head = document.createElement("div");
      head.className = `masu-row-actions-head ${this.rowActionsPin()}`;
      head.setAttribute("role", "columnheader");
      head.setAttribute("aria-colindex", String(this.columns.length + 1));
      head.setAttribute("aria-label", this.message("row_actions", {}));
      cells.push(head);
    }
    this.headerRow.replaceChildren(...cells);
    this.filters.renderChips();
  }

  messages(): Record<string, string> {
    return { ...DEFAULT_MESSAGES, ...this.config.messages };
  }

  applyWidths(): void {
    // The row actions' cell is a column of its own, pinned to the end.
    const extra = this.hasRowActions() ? [ROW_ACTIONS_WIDTH] : [];
    this.room = this.gridEl.clientWidth;
    this.widths = fill(
      this.sizes,
      this.columns.map((column) => column.grow ?? 0),
      this.room - extra.reduce((a, b) => a + b, 0),
    );
    const widths = [...this.widths, ...extra];
    this.contentEl.style.setProperty("--masu-cols", widths.map((width) => `${width}px`).join(" "));
    this.contentEl.style.setProperty("--masu-width", `${widths.reduce((a, b) => a + b, 0)}px`);
    this.pinned = pins([...this.columns.map((column) => column.pinned ?? null), ...extra.map(() => "end" as const)], widths);
    for (const [col, offset] of [...this.pinned.start, ...this.pinned.end]) {
      this.contentEl.style.setProperty(`--masu-pin-${col}`, `${offset}px`);
    }
  }

  private makeFormatters(): void {
    const locale = this.config.locale ?? undefined;
    this.formatters = this.columns.map((column) => {
      const format = formatter(column.type, locale, column.decimals, column.raw);
      return column.many ? manyFormatter(format) : format;
    });
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

  private planRequests(first: number, last: number, within: [number, number] | null = null): void {
    if (this.requestTimer) clearTimeout(this.requestTimer);
    // Rows ahead of the screen, but not past a page's.
    const from = within ? Math.max(first - PREFETCH, within[0]) : first - PREFETCH;
    const to = within ? Math.min(last + PREFETCH, within[1]) : last + PREFETCH;
    if (this.cache.missing(from, to, this.span()).length === 0) {
      this.stale = null;
      return;
    }
    const ask = () => {
      this.requestTimer = null;
      // One batch at a time: when it comes, the grid asks for the rows
      // on the screen then, not for those it passed by.
      if (this.cache.busy()) return;
      for (const block of this.cache.missing(from, to, this.span())) this.request(block);
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
    const take = (answer: BlockReply) => {
      if (answer.failed) {
        // The grid shows the error; Run again reads anew.
        cache.failed(block);
        return;
      }
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
      if (answer.total !== this.total || (answer.exact !== false) !== this.exact) this.setTotal(answer.total, answer.exact !== false);
      this.schedule();
      then?.();
    };
    this.transport.push("masu:rows", { from: block * cache.size, count: cache.size }, (reply) => {
      const answer = reply as unknown as BlockReply;
      // The rows come later: in a `masu:block` event, or with a new revision.
      if (answer.pending) {
        this.blockWaiters.set(answer.from, take);
        return;
      }
      take(answer);
    });
  }

  /** Asks for the rows from `first` to `last` that the cache lacks, then calls `done`. */
  load(first: number, last: number, done: () => void): void {
    const blocks = this.cache.missing(first, last, this.span());
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

  // Events: wired here, and handled by the core or by a feature (the
  // keyboard's, the pointer's).

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
    this.on(this.gridEl, "scroll", () => this.onScroll(), { passive: true });
    this.on(this.gridEl, "wheel", (event) => this.onWheel(event as WheelEvent), { passive: false });
    // A detail's own keys and clicks are its own (it may hold a grid).
    this.on(this.gridEl, "keydown", (event) => {
      if (this.details.inDetail(event.target)) this.details.onDetailKey(event);
      else this.keyboard.onKeyDown(event);
    });
    this.on(this.gridEl, "mousedown", (event) => {
      if (this.details.inDetail(event.target)) return;
      this.activation.onMouseDown(event);
      this.pointer.onMouseDown(event);
    });
    this.on(this.gridEl, "dblclick", (event) => {
      if (!this.details.inDetail(event.target)) this.pointer.onDoubleClick(event);
    });
    this.on(this.gridEl, "click", (event) => {
      if (this.details.inDetail(event.target)) return;
      const target = event.target as HTMLElement;
      // The boxes: the server holds the selection, the box shows it.
      if (target.closest(".masu-select-all")) {
        event.preventDefault();
        // Every row, unless every row is selected: then none.
        this.rowSelection.chooseAll(!(this.rowSelection.chosen.all && this.rowSelection.chosen.except.size === 0));
        return;
      }
      if (target.closest(".masu-select")) {
        event.preventDefault();
        const cell = this.cellAt(target);
        if (cell) this.rowSelection.onBox(cell.row, event.shiftKey);
        return;
      }
      if (target.closest(".masu-add-row")) {
        event.preventDefault();
        this.newRows.addDraft();
        return;
      }
      const more = target.closest<HTMLElement>(".masu-row-actions-button");
      if (more) {
        event.preventDefault();
        const rowEl = more.closest<RowElement>(".masu-row");
        if (rowEl?.masuIndex !== undefined) this.actions.openRowMenu(rowEl.masuIndex, more);
        return;
      }
      const button = target.closest<HTMLElement>(".masu-filter-button");
      if (!button) {
        this.activation.onClick(event);
        return;
      }
      const col = Number(button.dataset.col);
      if (this.filters.menu?.col === col && !this.filters.menu.from) this.filters.closeMenu(true);
      else this.filters.openMenu(col);
    });
    this.on(this.gridEl, "contextmenu", (event) => this.actions.onContextMenu(event));
    this.on(this.el, "contextmenu", (event) => {
      if (performance.now() - this.menuKeyAt < 1000 && (this.actions.cellMenu || this.filters.menu)) event.preventDefault();
    });
    this.on(document, "mousedown", (event) => {
      const panel = this.actions.actionPanel();
      if (panel && !panel.contains(event.target as Node)) this.actions.closeActionPanel(false);
    });
    this.on(this.filters.chipsEl, "click", (event) => this.filters.onChipClick(event));
    this.on(this.el, "click", (event) => {
      const person = (event.target as HTMLElement).closest<HTMLElement>(".masu-person[data-person]");
      if (person && person.closest(".masu") === this.el) this.peers.toggleFollow(person.dataset.person!);
    });
    // The person's own scrolling, clicking or typing ends a follow, in the
    // whole room (Issho's): the grid keeps the view it shows.
    for (const type of ["wheel", "touchstart", "mousedown", "keydown"] as const) {
      this.on(this.gridEl, type, () => this.peers.goOwnWay(), { passive: true });
    }
    // The copy of a grid the person uses (a grid twice on a page: a
    // document with the same view twice) says where they are; the others
    // say nothing.
    for (const type of ["pointerenter", "pointerdown", "focusin"] as const) {
      this.on(this.el, type, () => {
        const doc = this.el.dataset.isshoDoc;
        if (doc) activeIn.set(doc, this);
      }, { passive: true });
    }
    this.cleanups.push(() => {
      const doc = this.el.dataset.isshoDoc;
      if (doc && activeIn.get(doc) === this) activeIn.delete(doc);
    });
    // The person's pointer over a cell, for the others, when no Issho
    // pointers of the grid's room are on the page (a grid in a document of
    // another room): Issho's would share it, and the grid takes their place.
    this.on(this.el, "pointermove", (event) => {
      const move = event as PointerEvent;
      if (move.pointerType === "touch") return;
      this.peers.sharePointer(this.peers.cellUnder(move.clientX, move.clientY));
    }, { passive: true });
    this.on(this.el, "pointerleave", () => this.peers.sharePointer(null), { passive: true });
    // Whom the room is followed in: from this grid's people, the page's
    // people list, or any block of the room.
    const onFollowing = (event: Event): void => {
      const detail = (event as CustomEvent<{ room?: string; key?: string | null }>).detail;
      if (!this.peers.followRoom() || detail?.room !== this.peers.followRoom()) return;
      if (detail.key) this.peers.startFollowing(detail.key);
      else this.peers.stopFollowing(false);
    };
    document.addEventListener("issho:following", onFollowing);
    this.cleanups.push(() => document.removeEventListener("issho:following", onFollowing));
    this.on(this.gridEl, "focus", () => this.schedule());
    // Focus that leaves the grid (not for its editor or its questions)
    // saves the new row it was on.
    this.on(this.gridEl, "focusout", (event) => {
      const next = (event as FocusEvent).relatedTarget as Node | null;
      if (next && this.el.contains(next)) return;
      setTimeout(() => {
        if (this.editing.editor || this.el.contains(document.activeElement)) return;
        const draft = this.draftAt(this.active.row);
        if (draft) this.newRows.saveDrafts([draft.id]);
      }, 0);
    });
    this.on(document, "mousemove", (event) => this.pointer.onMouseMove(event));
    this.on(document, "mouseup", () => {
      this.dragging = false;
      this.layout.releaseHeader();
    });
    this.on(document, "copy", (event) => this.clipboard.onCopy(event));
    this.on(document, "paste", (event) => this.editing.onPaste(event));

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
      this.observer = new ResizeObserver(() => {
        // A column that grows takes the room of the box as it is now.
        if (this.gridEl.clientWidth !== this.room && this.columns.some((column) => (column.grow ?? 0) > 0)) this.applyWidths();
        this.schedule();
      });
      this.observer.observe(this.gridEl);
    }
  }

  private search(text: string): void {
    const search = text.trim() === "" ? null : text.trim();
    if (search === this.query.search) return;
    this.setQuery({ ...this.query, search });
  }

  /** Sorts by one column, in one direction, or by none (null). */
  setSort(col: number, dir: "asc" | "desc" | null): void {
    const column = this.columns[col];
    if (!column?.sortable) return;
    this.setQuery({ ...this.query, sorts: dir ? [{ key: column.key, dir }] : this.query.sorts.filter((sort) => sort.key !== column.key) });
  }

  sortBy(col: number, additive: boolean): void {
    const column = this.columns[col];
    if (!column?.sortable) return;
    const several = additive && this.config.multiSort !== false;
    this.setQuery({ ...this.query, sorts: nextSorts(this.query.sorts, column.key, several) });
  }

  cellAt(element: HTMLElement): Cell | null {
    const cellEl = element.closest<HTMLElement>(".masu-cell");
    const rowEl = cellEl?.parentElement as RowElement | null;
    if (!cellEl || !rowEl || rowEl.masuIndex === undefined || rowEl.parentElement !== this.body) return null;
    return { row: rowEl.masuIndex, col: Array.prototype.indexOf.call(rowEl.children, cellEl) };
  }

  // The rows of the query and the new rows: how many, where each is, and
  // the count.

  /** A block of rows from an answer: of this revision, or of the next, which comes with the server's render. */
  takeBlock(answer: BlockReply): void {
    if (answer.revision === this.revision) {
      this.cache.store(answer.from, answer.rows);
      this.schedule();
    } else if (answer.revision > this.revision) {
      this.pendingBlock = answer;
    }
  }

  /** Says once that part of a view no longer applies (Masu.View). */
  private showNotice(): void {
    const notice = this.config.notice;
    if (!notice || notice[0] === this.lastNotice) return;
    this.lastNotice = notice[0];
    this.announce(this.message("view_dropped", { label: notice[1] }));
  }

  /** Draws the rows on the screen again, with their errors and marks. */
  refreshRows(): void {
    for (const rowEl of this.rows.values()) rowEl.masuRow = undefined;
    this.render();
  }

  /** The rows the grid draws: the query's, the drafts, the row that adds one. */
  rowCount(): number {
    return this.span() + this.newRows.drafts.length + (this.config.creates ? 1 : 0);
  }

  /** The index of the row that adds one, or -1. */
  addIndex(): number {
    return this.config.creates ? this.span() + this.newRows.drafts.length : -1;
  }

  /** The row at an index: the query's (as the browser has it), or a draft's. */
  dataAt(index: number): Row | undefined {
    if (index < this.span()) return this.cache.get(index) ?? this.stale?.get(index);
    return this.newRows.drafts[index - this.span()]?.row;
  }

  draftAt(index: number): Draft | undefined {
    return index >= this.span() ? this.newRows.drafts[index - this.span()] : undefined;
  }

  /**
   * The rows of the query the grid scrolls over: its count, or, while the
   * count is not known, the rows read and a block more (a page more), which
   * grow as blocks come back full.
   */
  span(): number {
    if (this.exact) return this.total;
    return this.paged() ? Math.max(this.total, this.base() + this.config.pageSize) : this.total + GROW;
  }

  paged(): boolean {
    return this.config.paging === "pages";
  }

  /** The first row the body holds: 0, or the page's first. */
  base(): number {
    return this.paged() ? this.config.page * this.config.pageSize : 0;
  }

  /** The index after the last row the body holds: every row's, or the page's (the last page with the new rows). */
  end(): number {
    const count = this.rowCount();
    if (!this.paged()) return count;
    const pageEnd = this.base() + this.config.pageSize;
    return this.exact && pageEnd >= this.total ? count : Math.min(pageEnd, count);
  }

  /** The open details of the rows the body holds, by their place in it. */
  private localGaps(): Gap[] {
    const base = this.base();
    if (base === 0 && !this.paged()) return this.details.gaps;
    const end = this.end();
    return this.details.gaps.filter((gap) => gap.index >= base && gap.index < end).map((gap) => ({ index: gap.index - base, height: gap.height }));
  }

  /** Asks the server for the count (once a revision), then `then`. */
  askCount(then?: () => void): void {
    if (this.countAsked || this.exact) {
      then?.();
      return;
    }
    this.countAsked = true;
    this.transport.push("masu:count", {}, (reply) => {
      // Counted in a task: the count comes with the server's render.
      if (reply.pending) {
        this.countWaiter = () => {
          this.render();
          then?.();
        };
        return;
      }
      if (reply.revision === this.revision && typeof reply.total === "number") this.setTotal(reply.total, reply.exact !== false);
      this.render();
      then?.();
    });
  }

  /** Whether the person may edit the cell of `col` of a row (a draft: of a column a new row takes). */
  edits(data: Row, col: number): boolean {
    const column = this.columns[col];
    if (!column) return false;
    if (isDraft(data)) return column.creatable === true;
    return column.editable === true && !this.editing.locked(data, col);
  }

  /**
   * A new count of the query's rows, which moves the drafts: the active
   * cell stays on the draft, or the row that adds one, it was on.
   */
  setTotal(total: number, exact = this.exact): void {
    const draft = this.draftAt(this.active.row);
    const adding = this.active.row >= 0 && this.active.row === this.addIndex();
    this.total = total;
    this.exact = exact;
    if (draft) this.active = { row: this.span() + this.newRows.drafts.indexOf(draft), col: this.active.col };
    else if (adding) this.active = { row: this.addIndex(), col: this.active.col };
  }

  // Scrolling to a cell, and the range selected.

  /** The index of a row on the screen, by its id. */
  indexOf(id: unknown): number | undefined {
    const wanted = JSON.stringify(id);
    for (const [index, rowEl] of this.rows) {
      if (rowEl.masuRow && JSON.stringify(rowEl.masuRow[0]) === wanted) return index;
    }
    return undefined;
  }

  scrollToCell(index: number, col: number): void {
    const rh = this.config.rowHeight;
    const view = this.gridEl.clientHeight - this.head.offsetHeight;
    const top = this.rowTop(index);
    const y = this.contentTop();
    if (top < y || top + rh > y + view) {
      this.scrollToContent(Math.max(0, top - (view - rh) / 2));
    }
    this.scrollToColumn(col);
    this.schedule();
  }

  /** Scrolls sideways to show a column, unless it shows: the pinned ones always do. */
  private scrollToColumn(col: number): void {
    const scroll = scrollFor(col, this.widths, this.pinned, Math.abs(this.gridEl.scrollLeft), this.gridEl.clientWidth);
    if (scroll !== null) this.gridEl.scrollLeft = scroll;
  }

  /** The cells a copy takes: the range, or the active cell. */
  selection(): Rect | null {
    if (this.active.row < 0) return null;
    return rect(this.anchor ?? this.active, this.active);
  }

  /** The range that shows as selected: only one that the person made. */
  highlight(): Rect | null {
    return this.anchor && this.active.row >= 0 ? rect(this.anchor, this.active) : null;
  }

  pageRows(): number {
    return Math.max(1, Math.floor((this.gridEl.clientHeight - this.head.offsetHeight) / this.config.rowHeight) - 1);
  }

  ensureVisible(cell: Cell): void {
    const rh = this.config.rowHeight;
    const headHeight = this.head.offsetHeight;
    if (cell.row >= 0) {
      const top = this.rowTop(cell.row);
      const bottom = top + rh;
      const viewTop = this.contentTop();
      const viewBottom = viewTop + this.gridEl.clientHeight - headHeight;
      if (top < viewTop) this.scrollToContent(top);
      else if (bottom > viewBottom) this.scrollToContent(bottom - (this.gridEl.clientHeight - headHeight));
    }
    this.scrollToColumn(cell.col);
  }

  // Words for a screen reader.

  message(name: string, values: MessageValues): string {
    const messages = this.messages();
    const template = name === "rows" && values.count === 1 ? messages.row : messages[name] ?? name;
    return this.fill(template, { count: 0, ...values });
  }

  /** A message's `{count}`, `{label}`, `{done}` and `{total}`, the numbers in the grid's locale. */
  fill(template: string, values: MessageValues): string {
    const number = (n: number | undefined) => (n === undefined ? "" : new Intl.NumberFormat(this.config.locale ?? undefined).format(n));
    return template
      .replace("{count}", number(values.count))
      .replace("{label}", values.label ?? "")
      .replace("{done}", number(values.done))
      .replace("{total}", number(values.total));
  }

  announceCount(): void {
    this.announce(this.message(this.exact ? "rows" : "rows_more", { count: this.total }));
  }

  announceCopy(count: number): void {
    this.announce(this.message(count === 1 ? "copied_one" : "copied", { count }));
  }

  announce(text: string): void {
    if (this.statusEl) this.statusEl.textContent = text;
  }
}

