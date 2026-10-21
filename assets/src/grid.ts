// The grid in the browser. The server renders its structure and first
// rows (Masu.Grid); the grid takes them over and from then on draws only
// the rows on the screen, a few more on each side, reusing their
// elements as the person scrolls. The rows it lacks it asks the server
// for, a block at a time (BlockCache), once the scrolling pauses.
//
// Focus stays on the grid element; the active cell is its
// aria-activedescendant, so that a screen reader follows it while the
// rows come and go.

import { ActionMenu, type MenuItem } from "./actions";
import { BlockCache } from "./blocks";
import { allows, describe, replaceFilter } from "./filters";
import { fromTSV, inputText, invalid, matching, placePaste, sendValue, shownValue } from "./parse";
import { FilterMenu } from "./menu";
import { drop, floats, follow, lift, place as placeAt } from "./float";
import { copyText, formatter, manyFormatter, type Formatter } from "./format";
import { contains, move, rect, visibleRows, type Cell, type Rect } from "./geometry";
import { moveKey, pins, scrollFor, visualLeft, type Pins } from "./layout";
import { indexAt, rowTop, totalHeight, type Gap } from "./offsets";
import { boxHeight, clamp, toContent, toScroll, wheelPixels } from "./scroll";
import { ColumnsPanel, ExportPanel, ViewsPanel } from "./panels";
import { nextSorts } from "./sorting";
import { toTSV } from "./tsv";
import { sameView } from "./view";
import type {
  ActionItem,
  BlockReply,
  CellEditor,
  CellEditorFactory,
  CellValue,
  ColumnConfig,
  ColumnType,
  Config,
  FilterSpec,
  Options,
  Person,
  Progress,
  QuerySpec,
  Reply,
  Row,
  RowsAction,
  Transport,
} from "./types";

const options: Options = {};

/**
 * Options of every grid of the page: `peerLabel`, a function that draws
 * the label of another person on their cell (its Issho room).
 */
export function configure(next: Options): void {
  Object.assign(options, next);
}

const OVERSCAN = 8;
/** The rows more than it knows that a grid without a count scrolls over: a block. */
const GROW = 100;
const PREFETCH = 60;
const REQUEST_DELAY = 40;
const SEARCH_DELAY = 250;
const MAX_COPY_ROWS = 10_000;
const MAX_AUTO_WIDTH = 640;
const FLASH = 1600;
const CURSOR_DELAY = 150;
/** The width of the cell at the end of each row with its row actions' button. */
const ROW_ACTIONS_WIDTH = 40;
/** How long the line of an action's result stays. */
const TASK_SHOWN = 6000;

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
  /** The count is the query's; else the rows read, and maybe more. */
  private exact = true;
  /** The count was asked for (`masu:count`) in this revision. */
  private countAsked = false;
  private revision: number;
  private query: QuerySpec;
  private cache: BlockCache;
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
  /** The menu of a cell: the grid's items and the app's (Masu.Action). */
  private cellMenu: ActionMenu | null = null;
  /** Where the panel of an item (Masu.Action), which the server renders, goes: a header (row -1) or a cell. */
  private actionAnchor: { col: number; row: number; focus: boolean } | null = null;
  private wiredPanels = new WeakSet<HTMLElement>();
  /** Places the server's panel again as the page scrolls, while it is open. */
  private panelFollow: (() => void) | null = null;
  /** When a menu opened by its key: the browser follows the key with a contextmenu event, on the menu. */
  private menuKeyAt = 0;
  /** Where the pinned columns stick. */
  private pinned: Pins = pins([], []);
  /** The toolbar's buttons and their menus. */
  private columnsButton: HTMLButtonElement | null = null;
  private viewsButton: HTMLButtonElement | null = null;
  private exportButton: HTMLButtonElement | null = null;
  private panel:
    | { kind: "columns"; panel: ColumnsPanel }
    | { kind: "views"; panel: ViewsPanel }
    | { kind: "export"; panel: ExportPanel }
    | null = null;
  /** A block of a revision the grid does not have yet (a layout's answer). */
  private pendingBlock: BlockReply | null = null;
  private lastNotice = 0;
  /** The rows selected (`selectable`), as JSON ids; every row of the query less `except` when `all`. */
  private chosen = { all: false, ids: new Set<string>(), except: new Set<string>(), count: 0 };
  /** The row of the last box clicked: the start of a Shift click's range. */
  private lastChosen: number | null = null;
  private selectionBar: HTMLElement | null = null;
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
  /** The height of the rows, and the place of the screen's top in them (see scroll.ts). */
  private contentHeight = 0;
  private content = 0;
  /** The scrollTop the grid set last, in a grid taller than a browser draws. */
  private wrote: number | null = null;
  private queries = 0;
  /** The cell being edited. */
  private editor: Editor | null = null;
  /** The cell being edited with a form of the app's, which the server renders in a popover. */
  private formEditor: FormEditor | null = null;
  /** Places the form editor's popover again as the page scrolls. */
  private formFollow: (() => void) | null = null;
  /** The errors of cells the server did not save, by cellKey(). */
  private errors = new Map<string, string>();
  /** The cells being saved, by cellKey(). */
  private saving = new Set<string>();
  private undoStack: Step[] = [];
  private redoStack: Step[] = [];
  /** Edits sent and not answered; an undo or a redo before their answer waits for it. */
  private inFlight = 0;
  private waiting: ("undo" | "redo")[] = [];
  /**
   * New rows not saved yet (`create`), after the rows of the query, then
   * the row that adds one: each saves when the person leaves it.
   */
  private drafts: Draft[] = [];
  private draftCount = 0;
  /** On its way to the last page, to add a row there. */
  private toLastPage = false;
  /** The draft the active cell was on, saved when it leaves it. */
  private activeDraft: string | null = null;
  /** A question above the grid: delete rows, add the rest of a paste, an action's `confirm`. */
  private confirmEl: HTMLElement | null = null;
  /** The writes and actions that go on later (Masu.Write.async/1, `:async`), by their token. */
  private later = new Map<string, Later>();
  /** Lines above the grid: an action that runs, how far it is, how it went. */
  private tasksEl: HTMLElement | null = null;
  /** The history of a cell or a row (Masu.History), in a popover. */
  private historyEl: { el: HTMLElement; cleanup: () => void } | null = null;

  /** The rows that changed (Masu.Live), each until its flash ends. */
  private flash = new Map<string, { until: number; color: string | undefined }>();
  /** The other people who have the grid open, and their marks. */
  private people: Person[] = [];
  private peerEls: HTMLElement[] = [];
  // Each person's mark on their cell, kept from one drawing to the next so
  // that it glides to their next cell; and when a range they selected from
  // a cell began to sweep over its rows.
  private peerMarks = new Map<string, HTMLElement>();
  private peerHadRange = new Map<string, boolean>();
  private peerSweeps = new Map<string, number>();
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
  /** A query whose rows come later (`load={:async}`, `on_query`): what to do when they come. */
  private pendingQuery: { origin: "self" | "follow" | "restore"; then?: () => void } | null = null;
  /** The blocks asked for whose rows come in a `masu:block` event, by their first row. */
  private blockWaiters = new Map<number, (answer: BlockReply) => void>();
  /** What waits for a count that comes with the server's render. */
  private countWaiter: (() => void) | null = null;
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
    // Issho's pointer of an agent at work in the grid goes to its cell
    // (Issho's `locate`, through the symbol it reads, with no import of it).
    const locator = (at: unknown) => this.locate(at);
    (el as unknown as Record<symbol, unknown>)[Symbol.for("issho.locator")] = locator;
    this.cleanups.push(() => {
      const element = el as unknown as Record<symbol, unknown>;
      if (element[Symbol.for("issho.locator")] === locator) delete element[Symbol.for("issho.locator")];
    });
    this.transport = transport;
    this.config = readConfig(el);
    this.columns = this.config.columns;
    this.widths = this.columns.map((column) => column.width);
    this.total = this.config.total;
    this.exact = this.config.exact !== false;
    this.revision = this.config.revision;
    this.query = this.config.query;
    this.cache = cacheFor(this.config);

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
    this.readSelection();
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
    const columnsChanged =
      JSON.stringify(withoutWidths(config.columns)) !== JSON.stringify(withoutWidths(previous.columns)) ||
      (config.rowActions?.length ?? 0) > 0 !== (previous.rowActions?.length ?? 0) > 0;
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
      for (const draft of this.drafts) draft.row = this.draftRow(draft);
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
    if (this.readSelection()) {
      this.renderHeader();
      this.refreshRows();
    }
    this.renderToolbar();
    this.renderTotals();
    this.showNotice();
    this.measureDetails();
    this.placeActionPanel();
    this.placeFormEditor();

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
    this.closeMenu(false);
    this.closeCellMenu(false);
    this.closePanel(false);
    this.detailObserver?.disconnect();
    this.patchObserver?.disconnect();
    this.editor?.el.remove();
    this.editor = null;
    this.unfollowPanel();
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
      // Its rows come with the server's render (a new revision).
      if (answer.pending && !answer.error) {
        this.querying = true;
        this.pendingQuery = { origin, then };
        this.showBusy();
        return;
      }
      if (answer.error) {
        if (origin === "follow") this.refusedView = JSON.stringify(query);
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
    // The rows the body holds: every row, or a page's (`paging`).
    const base = this.base();
    const count = this.end() - base;
    const gaps = this.localGaps();
    this.contentHeight = totalHeight(count, rh, gaps);
    setStyle(this.body, "height", `${boxHeight(this.contentHeight)}px`);
    if (!this.scaled()) this.content = this.gridEl.scrollTop;
    const y = this.contentTop();
    // Where the rows are drawn: their place in the content, less the
    // content above the scroll box's top (none in most grids).
    const shift = y - this.gridEl.scrollTop;
    // -1 while the count is not known (ARIA).
    setAttribute(this.gridEl, "aria-rowcount", this.exact ? String(this.rowCount() + 1) : "-1");
    setAttribute(this.gridEl, "aria-colcount", String(this.columns.length + (this.hasRowActions() ? 1 : 0)));
    if (this.emptyEl) this.emptyEl.hidden = this.total > 0 || this.drafts.length > 0;
    this.leaveDraft();

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
      if (index === this.addIndex()) this.fillAddRow(rowEl, index);
      else this.fillRow(rowEl, index, this.dataAt(index) ?? null);
      this.markRow(rowEl, index, selection);
    }

    this.markHeader(selection);
    this.updateActiveDescendant();
    if (this.editor) this.editor.el.style.insetInlineStart = `${this.colLeft(this.editor.col)}px`;
    this.placeDetails(headHeight);
    this.drawPeople();
    this.reportCursor();
    this.cache.evict(this.cache.blockOf(first));
    // A page reads its own rows, and no other page's.
    this.planRequests(first, Math.min(last, this.span() - 1), this.paged() ? [base, this.end() - 1] : null);
    // At the end of the rows it knows, a grid that does not know its
    // count asks for it, once.
    if (!this.exact && !this.paged() && count > 0 && local.last >= this.span() - 1) this.askCount();
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
      const error = row === null ? undefined : this.errors.get(key);
      cell.classList.toggle("masu-invalid", error !== undefined);
      cell.classList.toggle("masu-saving", row !== null && this.saving.has(key));
      const edits = draft ? column.creatable === true : column.editable === true;
      const locked = row !== null && edits && this.locked(row, col);
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
  private rowActionsOf(row: Row): [number, boolean, string | null][] {
    if (!this.hasRowActions() || isGroup(row) || isDraft(row)) return [];
    const own = (row as unknown[])[this.afterCells()];
    return Array.isArray(own) ? (own as [number, boolean, string | null][]) : [];
  }

  /** The place in the tree of a row (Masu.Tree), after its cells, its read-only cells and its row actions. */
  private nodeOf(row: Row): TreeNode | null {
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
      const column = this.catalogColumn(key);
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
    if (this.config.selection && !isGroup(row) && !isDraft(row)) {
      const box = document.createElement("input");
      box.type = "checkbox";
      box.className = "masu-select";
      box.tabIndex = -1;
      box.checked = this.isChosen(row[0]);
      box.setAttribute("aria-label", this.message("select_row", {}));
      cell.prepend(box);
    }
    cell.parentElement?.classList.toggle("masu-row-chosen", this.config.selection !== null && !isGroup(row) && this.isChosen(row[0]));
  }

  // Selection (`selectable`): the server holds it; the browser shows it
  // at once, and sends each change.

  /** Reads the selection of the config; whether it changed. */
  private readSelection(): boolean {
    const selection = this.config.selection;
    const before = JSON.stringify([this.chosen.all, [...this.chosen.ids], [...this.chosen.except]]);
    this.chosen = selection
      ? {
          all: selection.all,
          ids: new Set(selection.ids.map((id) => JSON.stringify(id))),
          except: new Set(selection.except.map((id) => JSON.stringify(id))),
          count: selection.count,
        }
      : { all: false, ids: new Set(), except: new Set(), count: 0 };
    this.renderSelectionBar();
    return JSON.stringify([this.chosen.all, [...this.chosen.ids], [...this.chosen.except]]) !== before;
  }

  private isChosen(id: unknown): boolean {
    const key = JSON.stringify(id);
    return this.chosen.all ? !this.chosen.except.has(key) : this.chosen.ids.has(key);
  }

  /** Selects or takes out rows by their indexes (those the browser has, or loads). */
  private choose(first: number, last: number, on: boolean): void {
    const top = Math.min(first, last);
    const bottom = Math.min(Math.max(first, last), top + MAX_EDITS - 1);
    this.load(top, bottom, () => {
      const ids: unknown[] = [];
      for (let index = top; index <= bottom; index++) {
        const row = this.cache.get(index);
        if (row && !isGroup(row)) ids.push(row[0]);
      }
      if (ids.length === 0) return;
      for (const id of ids) {
        const key = JSON.stringify(id);
        if (this.chosen.all) (on ? this.chosen.except.delete(key) : this.chosen.except.add(key));
        else on ? this.chosen.ids.add(key) : this.chosen.ids.delete(key);
      }
      this.refreshRows();
      // The header's box: every row, some, or none.
      this.renderHeader();
      this.transport.push("masu:select", { ids, on }, (reply) => {
        if (typeof reply?.count === "number") this.announce(this.message("chosen", { count: reply.count as number }));
      });
    });
  }

  /** The box of a row was clicked (Shift: the range from the last one). */
  private onBox(index: number, shift: boolean): void {
    const row = this.dataAt(index);
    if (!row) return;
    const on = !this.isChosen(row[0]);
    if (shift && this.lastChosen !== null) this.choose(this.lastChosen, index, on);
    else this.choose(index, index, on);
    this.lastChosen = index;
  }

  /** Every row of the query, or none. */
  private chooseAll(on: boolean): void {
    this.chosen = { all: on, ids: new Set(), except: new Set(), count: on ? this.total : 0 };
    this.refreshRows();
    this.renderHeader();
    this.transport.push("masu:select", { all: on }, (reply) => {
      if (typeof reply?.count === "number") this.announce(this.message("chosen", { count: reply.count as number }));
    });
  }

  /** "1,234 selected", with Clear, above the grid while rows are selected. */
  private renderSelectionBar(): void {
    if (!this.config.selection || this.chosen.count === 0) {
      this.selectionBar?.remove();
      this.selectionBar = null;
      return;
    }
    if (!this.selectionBar) {
      this.selectionBar = document.createElement("div");
      this.selectionBar.className = "masu-selection-bar";
      this.uiEl.appendChild(this.selectionBar);
    }
    const text = document.createElement("span");
    const all = this.chosen.all && this.chosen.except.size === 0;
    text.textContent = this.message(all ? (this.config.selection.exact === false ? "chosen_all_more" : "chosen_all") : "chosen", {
      count: this.chosen.count,
    });
    const clear = document.createElement("button");
    clear.type = "button";
    clear.className = "masu-selection-clear";
    clear.textContent = this.message("clear_selection", {});
    clear.addEventListener("click", () => this.chooseAll(false));
    this.selectionBar.replaceChildren(text);
    for (const action of this.config.actions ?? []) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `masu-selection-action${action.danger ? " masu-danger" : ""}`;
      button.textContent = action.label;
      button.addEventListener("click", () => this.runSelectionAction(action));
      this.selectionBar.appendChild(button);
    }
    this.selectionBar.appendChild(clear);
    if (this.config.deletes) {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "masu-selection-delete masu-danger";
      remove.textContent = this.message("delete", {});
      remove.addEventListener("click", () => this.confirmDelete(this.chosen.count, { selection: true }));
      this.selectionBar.insertBefore(remove, clear);
    }
  }

  /** The ids of the rows whose detail is open (as JSON). */
  private openDetails(): Set<string> {
    return new Set((this.config.details ?? []).map(([id]) => JSON.stringify(id)));
  }

  /** The top of a row, under the details open above it. */
  private rowTop(index: number): number {
    return rowTop(index - this.base(), this.config.rowHeight, this.localGaps());
  }

  /** Where a row is drawn in the scroll box: its top, less the content above the box's top. */
  private rowY(index: number): number {
    return this.rowTop(index) - (this.contentTop() - this.gridEl.scrollTop);
  }

  /** The row at the top of the screen. */
  private indexAtTop(): number {
    return indexAt(this.contentTop(), this.config.rowHeight, this.localGaps()) + this.base();
  }

  /** The first row the screen shows whole: where one who follows this person starts. */
  private firstWholeRow(): number {
    const index = this.indexAtTop();
    return this.rowTop(index) < this.contentTop() ? index + 1 : index;
  }

  // A grid taller than a browser draws (see scroll.ts): its scroll box
  // has a height of its own, and the grid keeps its place in the rows.
  // The scrollbar dragged moves it in proportion; a wheel, the keys and
  // the grid itself move it by pixels.

  private scaled(): boolean {
    return this.contentHeight > boxHeight(this.contentHeight);
  }

  /** The place of the screen's top in the rows: the scrollTop, in a grid of a height a browser draws. */
  private contentTop(): number {
    return this.scaled() ? this.content : this.gridEl.scrollTop;
  }

  /** Scrolls to a place in the rows. */
  private scrollToContent(top: number): void {
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

  /** A wheel moves a tall grid by its own pixels; at an end, it scrolls the page. */
  private onWheel(event: WheelEvent): void {
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
      setStyle(gap.el, "transform", `translate(${left}px, ${headHeight + this.rowY(gap.index) + rh}px)`);
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

  /** Opens or closes the detail of a row. */
  private toggleDetail(index: number, open?: boolean): void {
    const row = this.dataAt(index);
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

      if (col === 0 && this.config.selection) {
        const box = document.createElement("input");
        box.type = "checkbox";
        box.className = "masu-select-all";
        box.tabIndex = -1;
        box.checked = this.chosen.all && this.chosen.except.size === 0;
        box.indeterminate = !box.checked && (this.chosen.all || this.chosen.ids.size > 0);
        box.setAttribute("aria-label", this.message("select_all", {}));
        cell.appendChild(box);
      }

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

      if (this.hasHeaderMenu(col)) {
        const filtered = this.query.filters.some((filter) => filter.key === column.key);
        const filter = document.createElement("button");
        filter.type = "button";
        filter.tabIndex = -1;
        filter.className = "masu-filter-button";
        filter.dataset.col = String(col);
        filter.setAttribute("aria-label", this.message(column.filterable ? "filter" : "column_menu", { label: column.label }));
        filter.setAttribute("aria-haspopup", "dialog");
        filter.setAttribute("aria-expanded", this.menu?.col === col ? "true" : "false");
        if (filtered) filter.dataset.active = "true";
        filter.innerHTML = column.filterable ? FILTER_ICON : MORE_ICON;
        cell.appendChild(filter);
      }

      const resizer = document.createElement("span");
      resizer.className = "masu-resizer";
      resizer.setAttribute("aria-hidden", "true");
      cell.appendChild(resizer);
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
      const format = col >= 0 ? this.formatters[col] : formatter(column.type, this.config.locale ?? undefined, null, column.raw);
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

  /** Whether a column has a header menu: it filters, or has the app's items. */
  private hasHeaderMenu(col: number): boolean {
    const column = this.columns[col];
    return column !== undefined && (column.filterable || (column.headerActions?.length ?? 0) > 0);
  }

  /** Opens the header menu of a column (its filter, and the app's items), under its header. */
  openMenu(col: number): void {
    const column = this.columns[col];
    if (!column || !this.hasHeaderMenu(col)) return;
    this.closeMenu(false);
    this.closeCellMenu(false);
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
        actions: (column.headerActions ?? []).map((action) => ({
          label: action.label,
          run: () => this.runAction("header", action, col, -1, null),
        })),
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

  // The menu of a cell, and the items of the app's own (Masu.Action).

  private onContextMenu(event: MouseEvent): void {
    if (this.inDetail(event.target) || this.editor) return;
    // Opened by its key already, which the browser follows with this event.
    if (this.cellMenu || this.menu) {
      event.preventDefault();
      return;
    }
    const target = event.target as HTMLElement;
    const header = target.closest<HTMLElement>(".masu-hcell");
    if (header && header.parentElement === this.headerRow) {
      // A header's own menu, when the app has items for its headers.
      const col = Number(header.dataset.col);
      if ((this.columns[col]?.headerActions?.length ?? 0) > 0) {
        event.preventDefault();
        this.openMenu(col);
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
    const cell = target === this.gridEl ? (this.active.row >= 0 ? this.active : null) : this.cellAt(target);
    if (!cell) return;
    const at = target === this.gridEl ? null : { x: event.clientX, y: event.clientY };
    if (this.openCellMenu(cell, at)) event.preventDefault();
  }

  /**
   * Opens the menu of a cell, at a point (a click's) or under the cell.
   * Returns whether it has a menu: the grid's items (`cell_menu`) or the
   * app's, for a row of data (not a group's, nor a new row).
   */
  private openCellMenu(cell: Cell, at: { x: number; y: number } | null): boolean {
    const data = this.dataAt(cell.row);
    if (!data || isGroup(data) || isDraft(data)) return false;
    const items = this.cellItems(cell, data);
    if (items.length === 0) return false;

    this.closeMenu(false);
    this.closeCellMenu(false);
    this.closeActionPanel(false);
    if (!at) {
      this.ensureVisible(cell);
      this.render();
      const box = this.cellElement(cell)?.getBoundingClientRect();
      at = box ? { x: box.left, y: box.bottom } : { x: 0, y: 0 };
    }
    const column = this.columns[cell.col];
    this.cellMenu = new ActionMenu(
      { root: this.uiEl, label: this.message("cell_menu", { label: column.label }), close: (focus) => this.closeCellMenu(focus) },
      items,
      at,
    );
    return true;
  }

  private closeCellMenu(focus: boolean): void {
    if (!this.cellMenu) return;
    this.cellMenu.destroy();
    this.cellMenu = null;
    if (focus) this.gridEl.focus({ preventScroll: true });
  }

  private cellElement(cell: Cell): HTMLElement | null {
    if (cell.row < 0) return (this.headerRow.children[cell.col] as HTMLElement | undefined) ?? null;
    return (this.rows.get(cell.row)?.children[cell.col] as HTMLElement | undefined) ?? null;
  }

  /** The items of a cell's menu: copy, filter, sort (`cell_menu`), then the app's. */
  private cellItems(cell: Cell, data: Row): MenuItem[] {
    const column = this.columns[cell.col];
    const builtIn = this.config.cellMenu ?? [];
    const range = this.highlight();
    const inRange = range && contains(range, cell.row, cell.col) ? range : null;
    const items: MenuItem[] = [];
    const group = (more: MenuItem[]) => {
      if (more.length > 0) more[0].separated = true;
      items.push(...more);
    };

    if (builtIn.includes("copy")) {
      const copied = inRange ?? rect(cell, cell);
      group([
        { name: "copy", label: this.message("copy", {}), run: () => this.copyRange(copied, false) },
        { name: "copy-headers", label: this.message("copy_with_headers", {}), run: () => this.copyRange(copied, true) },
      ]);
    }

    // A cell of HEEx has its value only when it edits.
    const sent = data[cell.col + 1];
    const known = column.many || !column.html || Array.isArray(sent);
    if (builtIn.includes("filter") && column.filterable && known) {
      // Of many values: by none or some, not by the cell's values.
      const value = column.many ? null : rawValue(sent);
      const filter = (spec: FilterSpec) => () =>
        this.setQuery({ ...this.query, filters: replaceFilter(this.query.filters, column.key, spec) });
      // Only the filters the column's source runs.
      const more: MenuItem[] = [];
      if (value !== null) {
        const shown = clip(column.type === "boolean" ? this.message(value ? "yes" : "no", {}) : this.formatters[cell.col](value));
        const only: FilterSpec | null =
          column.type === "enum" && allows(column, "in")
            ? { key: column.key, op: "in", value: [value] }
            : allows(column, "eq")
              ? { key: column.key, op: "eq", value }
              : null;
        if (only) more.push({ name: "filter-value", label: this.message("filter_value", { label: shown }), run: filter(only) });
        if (allows(column, "neq")) {
          more.push({
            name: "exclude-value",
            label: this.message("exclude_value", { label: shown }),
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
            const words = this.message(`filter_${op}${timely ? "_time" : ""}`, { label: shown });
            more.push({ name: `filter-${op}`, label: words, run: filter({ key: column.key, op, value }) });
          }
        }
        if (text && allows(column, "contains")) {
          more.push({
            name: "filter-contains",
            label: this.message("filter_contains", { label: shown }),
            run: filter({ key: column.key, op: "contains", value }),
          });
        }
      }
      if (allows(column, "is_nil")) {
        const words = this.message(column.many ? "filter_none" : "filter_empty", {});
        more.push({ name: "filter-empty", label: words, run: filter({ key: column.key, op: "is_nil" }) });
      }
      if (allows(column, "not_nil")) {
        const words = this.message(column.many ? "filter_some" : "filter_not_empty", {});
        more.push({ name: "filter-not-empty", label: words, run: filter({ key: column.key, op: "not_nil" }) });
      }
      group(more);
    }

    if (builtIn.includes("sort") && column.sortable) {
      const sort = (dir: "asc" | "desc") => () => this.setQuery({ ...this.query, sorts: [{ key: column.key, dir }] });
      group([
        { name: "sort-asc", label: this.message("sort_asc", {}), run: sort("asc") },
        { name: "sort-desc", label: this.message("sort_desc", {}), run: sort("desc") },
      ]);
    }

    group(
      (column.cellActions ?? []).map((action) => ({
        label: action.label,
        run: () => this.runAction("cell", action, cell.col, cell.row, inRange),
      })),
    );
    group(this.rowItems(data));
    if (this.config.history) {
      group([
        { name: "history", label: this.message("history", {}), run: () => this.openHistory(cell, true) },
        { name: "row-history", label: this.message("row_history", {}), run: () => this.openHistory(cell, false) },
      ]);
    }
    return items;
  }

  /**
   * The history of a cell (or of its row): its values, newest first, who
   * set each and when, and Restore; Undo all for a batch of several cells
   * (someone's paste). In a popover under the cell, as a dialog.
   */
  private openHistory(cell: Cell, ofCell: boolean): void {
    const data = this.dataAt(cell.row);
    const column = this.columns[cell.col];
    if (!data || !column || isGroup(data) || isDraft(data)) return;
    this.closeHistory(false);
    this.closeCellMenu(false);

    const el = document.createElement("div");
    el.className = "masu-menu masu-panel masu-history";
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-label", ofCell ? this.message("history_of", { label: column.label }) : this.message("row_history", {}));
    el.tabIndex = -1;
    const list = document.createElement("ol");
    list.className = "masu-history-list";
    list.setAttribute("aria-busy", "true");
    el.appendChild(list);
    this.uiEl.appendChild(el);

    const place = () => {
      const box = (this.cellElement(cell) ?? this.gridEl).getBoundingClientRect();
      if (floats(el)) {
        lift(el);
        placeAt(el, { left: box.left, below: box.bottom + 4, above: box.top - 4 });
      } else {
        const root = this.el.getBoundingClientRect();
        el.style.top = `${box.bottom - root.top + 4}px`;
        el.style.insetInlineStart = `${Math.max(0, box.left - root.left)}px`;
      }
    };
    const unfollow = follow(place);
    el.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        this.closeHistory(true);
      }
    });
    const onDown = (event: Event) => {
      if (!el.contains(event.target as Node)) this.closeHistory(false);
    };
    document.addEventListener("mousedown", onDown);
    this.historyEl = {
      el,
      cleanup: () => {
        unfollow();
        document.removeEventListener("mousedown", onDown);
      },
    };
    place();
    el.focus();

    const payload: Record<string, unknown> = { id: data[0] };
    if (ofCell) payload.key = column.key;
    this.transport.push("masu:history", payload, (reply) => {
      if (this.historyEl?.el !== el) return;
      this.fillHistory(list, (reply.entries as HistoryEntry[]) ?? [], ofCell);
      list.setAttribute("aria-busy", "false");
      place();
      (el.querySelector<HTMLElement>("button") ?? el).focus();
    });
  }

  private fillHistory(list: HTMLElement, entries: HistoryEntry[], ofCell: boolean): void {
    if (entries.length === 0) {
      const empty = document.createElement("li");
      empty.className = "masu-history-empty";
      empty.textContent = this.message("history_empty", {});
      list.replaceChildren(empty);
      return;
    }
    const batches = new Set<string>();
    list.replaceChildren(
      ...entries.map((entry) => {
        const item = document.createElement("li");
        item.className = "masu-history-entry";
        const col = this.columns.findIndex((column) => column.key === entry.key);
        const format = (value: unknown) =>
          col >= 0 ? this.formatters[col](value as CellValue) || this.message("empty_value", {}) : String(value ?? "");

        const what = document.createElement("div");
        what.className = "masu-history-what";
        if (entry.op === "create") what.textContent = this.message("history_created", {});
        else if (entry.op === "delete") what.textContent = this.message("history_deleted", {});
        else {
          const label = !ofCell && col >= 0 ? `${this.columns[col].label}: ` : "";
          what.textContent = `${label}${format(entry.after)}`;
          const was = document.createElement("span");
          was.className = "masu-history-was";
          was.textContent = this.message("history_was", { label: format(entry.before) });
          what.append(" ", was);
        }

        const who = document.createElement("div");
        who.className = "masu-history-who";
        const origin = HISTORY_ORIGINS.includes(entry.origin) ? ` · ${this.message(`history_origin_${entry.origin}`, {})}` : "";
        const time = document.createElement("time");
        time.dateTime = entry.at;
        time.title = new Date(entry.at).toLocaleString(this.config.locale ?? undefined);
        time.textContent = this.ago(entry.at);
        who.append(`${entry.user ?? this.message("history_someone", {})} · `, time, origin);
        item.append(what, who);

        const actions = document.createElement("div");
        actions.className = "masu-history-actions";
        if (entry.op === "update" && col >= 0) {
          const restore = document.createElement("button");
          restore.type = "button";
          restore.className = "masu-history-restore";
          restore.textContent = this.message("history_restore", { label: format(entry.before) });
          restore.addEventListener("click", () => this.restoreHistory({ entry: entry.id }));
          actions.appendChild(restore);
        }
        if (entry.batch && entry.batch_size > 1 && !batches.has(entry.batch)) {
          batches.add(entry.batch);
          const all = document.createElement("button");
          all.type = "button";
          all.className = "masu-history-restore-batch";
          all.textContent = this.message("history_restore_batch", { count: entry.batch_size });
          all.addEventListener("click", () => this.restoreHistory({ batch: entry.batch }));
          actions.appendChild(all);
        }
        if (actions.childElementCount > 0) item.appendChild(actions);
        return item;
      }),
    );
  }

  /** How long ago, in the grid's locale ("2 minutes ago"). */
  private ago(at: string): string {
    const seconds = (new Date(at).getTime() - Date.now()) / 1000;
    const format = new Intl.RelativeTimeFormat(this.config.locale ?? undefined, { numeric: "auto" });
    const units: [Intl.RelativeTimeFormatUnit, number][] = [
      ["year", 31_536_000],
      ["month", 2_592_000],
      ["day", 86_400],
      ["hour", 3_600],
      ["minute", 60],
    ];
    for (const [unit, size] of units) {
      if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
    }
    return format.format(0, "second");
  }

  /** Brings a value of the history back (or a batch): an edit, which the server checks as any. */
  private restoreHistory(payload: { entry: string | null } | { batch: string | null }): void {
    this.closeHistory(true);
    this.transport.push("masu:history_restore", payload, (reply) => {
      const errors = (reply.errors as [unknown, string, string][]) ?? [];
      for (const [id, key, message] of errors) this.errors.set(cellKey(id, key), message);
      if (errors.length > 0) {
        const [, key, message] = errors[0];
        const column = this.columns.find((c) => c.key === key);
        this.announce(`${column?.label ?? key}: ${message}`);
      } else {
        this.announce(this.message("history_restored", { count: (reply.restored as number) ?? 0 }));
      }
      this.refreshRows();
    });
  }

  private closeHistory(focus: boolean): void {
    if (!this.historyEl) return;
    const { el, cleanup } = this.historyEl;
    this.historyEl = null;
    cleanup();
    drop(el);
    el.remove();
    if (focus) this.gridEl.focus({ preventScroll: true });
  }

  /** The items of a row's actions (Masu.Action): those it shows, links, disabled ones too. */
  private rowItems(data: Row): MenuItem[] {
    const actions = new Map((this.config.rowActions ?? []).map((action) => [action.id, action]));
    return this.rowActionsOf(data).flatMap(([id, disabled, href]) => {
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
  private openRowMenu(index: number, button: HTMLElement): void {
    const data = this.dataAt(index);
    if (!data || isGroup(data) || isDraft(data)) return;
    const items = this.rowItems(data);
    if (items.length === 0) return;
    this.closeMenu(false);
    this.closeCellMenu(false);
    this.closeActionPanel(false);
    this.active = { row: index, col: Math.max(0, this.active.col) };
    this.anchor = null;
    this.render();
    const box = button.getBoundingClientRect();
    this.cellMenu = new ActionMenu(
      { root: this.uiEl, label: this.message("row_actions", {}), close: (focus) => this.closeCellMenu(focus) },
      items,
      { x: box.left, y: box.bottom },
    );
  }

  /** Runs a row action on the server, after its question. */
  private runRowAction(action: RowsAction, data: Row): void {
    const run = () =>
      this.transport.push("masu:action", { kind: "row", action: action.id, label: action.label, id: data[0] }, (reply) =>
        this.actionReply(action.label, reply),
      );
    if (action.confirm) this.confirm(action.confirm, action.label, run, action.danger);
    else run();
  }

  /** Runs an action on the rows selected, after its question ("Delete {count} orders?"). */
  private runSelectionAction(action: RowsAction): void {
    const run = () => {
      this.selectionBar?.querySelectorAll("button").forEach((button) => (button.disabled = true));
      this.transport.push("masu:action", { kind: "selection", action: action.id, label: action.label }, (reply) => {
        this.selectionBar?.querySelectorAll("button").forEach((button) => (button.disabled = false));
        this.actionReply(action.label, reply);
      });
    };
    if (action.confirm) this.confirm(this.fill(action.confirm, { count: this.chosen.count }), action.label, run, action.danger);
    else run();
  }

  /** What an action's answer says: done (with its message), failed, or going on until Masu.reply/2. */
  private actionReply(label: string, reply: Record<string, unknown>): void {
    if (typeof reply.async === "string") {
      this.later.set(reply.async, { kind: "action", label });
      this.showTask(reply.async, this.message("action_running", { label }), "running");
    } else if (typeof reply.failed === "string") {
      this.showTask(null, reply.failed, "error");
    } else if (reply.error) {
      this.showTask(null, this.message("action_failed", {}), "error");
    } else {
      const message = typeof reply.message === "string" ? reply.message : this.message("action_done", { label });
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
      this.uiEl.appendChild(this.tasksEl);
    }
    const existing = token ? this.tasksEl.querySelector<HTMLElement>(`[data-token="${CSS.escape(token)}"]`) : null;
    const line = existing ?? document.createElement("div");
    line.className = "masu-task";
    line.dataset.state = state;
    if (token) line.dataset.token = token;
    line.textContent = text;
    if (!existing) this.tasksEl.appendChild(line);
    this.announce(text);
    if (state !== "running") {
      delete line.dataset.token;
      setTimeout(() => line.remove(), TASK_SHOWN);
    }
  }

  /** A write or an action that went on later replied (Masu.reply/2). */
  receiveReply(reply: Reply): void {
    const later = this.later.get(reply.token);
    if (!later) return;
    this.later.delete(reply.token);

    if (later.kind === "action") {
      const text = reply.message ?? (reply.ok ? this.message("action_done", { label: later.label }) : this.message("action_failed", {}));
      this.showTask(reply.token, text, reply.ok ? "done" : "error");
    } else if (later.kind === "edits") {
      this.takeEditReply(later.edits, reply.errors as [unknown, string, string, CellValue?][], later.mode);
      if (reply.ok && reply.message) this.announce(reply.message);
    } else {
      const errors = reply.errors as [unknown, string][];
      if (!reply.ok) this.announce(errors[0]?.[1] ?? reply.message ?? this.message("action_failed", {}));
      else this.announce(reply.message ?? (later.count === 1 ? this.message("deleted_one", {}) : this.message("deleted", { count: later.count })));
    }
  }

  /** How far an action that went on later is (Masu.progress/3). */
  receiveProgress(progress: Progress): void {
    const later = this.later.get(progress.token);
    if (later?.kind !== "action") return;
    this.showTask(progress.token, this.message("action_progress", { label: later.label, done: progress.done, total: progress.total }), "running");
  }

  /** Copies a range, with its columns' labels first when `headers`. */
  private copyRange(range: Rect, headers: boolean): void {
    const last = Math.min(range.bottom, range.top + MAX_COPY_ROWS - 1);
    this.load(range.top, last, () => {
      const text = this.copyText(range.top, last, range, headers);
      const done = navigator.clipboard?.writeText(text);
      if (!done) {
        this.announce(this.message("copy_failed", {}));
        return;
      }
      done.then(
        () => this.announceCopy(last - range.top + 1),
        () => this.announce(this.message("copy_failed", {})),
      );
    });
  }

  /**
   * Runs an item of the app's (Masu.Action) on a header (row -1) or a
   * cell: its JS command here, and on the server its function, its event
   * or its panel. The server reads the row and the value itself.
   */
  private runAction(kind: "header" | "cell", action: ActionItem, col: number, row: number, range: Rect | null): void {
    const column = this.columns[col];
    if (!column) return;
    const data = row >= 0 ? this.dataAt(row) : undefined;
    if (kind === "cell" && !data) return;

    this.rangeIds(range, (ids) => {
      const keys = range ? this.columns.slice(range.left, range.right + 1).map((c) => c.key) : null;
      if (action.js) {
        const sent = data?.[col + 1];
        const detail: Record<string, unknown> = { grid: this.id, kind, action: action.label, column: column.key };
        if (data) {
          detail.id = data[0];
          detail.value = !column.html || Array.isArray(sent) ? rawValue(sent) : null;
        }
        if (ids && keys) detail.range = { ids, columns: keys };
        this.el.dispatchEvent(new CustomEvent("masu:action", { bubbles: true, detail }));
        this.transport.exec?.(action.js);
      }
      if (!action.server && !action.panel) return;

      const payload: Record<string, unknown> = { kind, action: action.id, label: action.label, key: column.key };
      if (data) payload.id = data[0];
      if (ids && keys) payload.range = { ids, keys };
      this.transport.push("masu:action", payload, (reply) => {
        if (reply.panel) {
          this.actionAnchor = { col, row, focus: true };
          this.placeActionPanel();
        } else if (reply.error) {
          this.announce(this.message("action_failed", {}));
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
    this.load(range.top, last, () => {
      const ids: unknown[] = [];
      for (let index = range.top; index <= last; index++) {
        const data = this.dataAt(index);
        if (data && !isGroup(data) && !isDraft(data)) ids.push(data[0]);
      }
      then(ids);
    });
  }

  /** The panel of an item that the server rendered, if open. */
  private actionPanel(): HTMLElement | null {
    const panel = this.el.querySelector<HTMLElement>(":scope > .masu-panels > .masu-action-panel");
    return panel && !panel.hidden ? panel : null;
  }

  /**
   * Places the server's panel under its header or cell, inside the
   * grid's element: again after each render, which takes its style away.
   */
  private placeActionPanel(): void {
    const panel = this.actionPanel();
    if (!panel) return this.unfollowPanel();
    const col = this.columns.findIndex((column) => column.key === panel.dataset.key);
    const anchor = this.actionAnchor ?? { col: Math.max(col, 0), row: -1, focus: false };
    const target = this.cellElement({ row: anchor.row, col: anchor.col }) ?? this.cellElement({ row: -1, col: anchor.col });
    const box = (target ?? this.gridEl).getBoundingClientRect();
    if (floats(panel)) {
      lift(panel);
      placeAt(panel, { left: box.left, below: box.bottom + 4, above: box.top - 4 }, (name, value) =>
        setStyle(panel, name, value),
      );
      this.panelFollow ??= follow(() => this.placeActionPanel());
    } else {
      const root = this.el.getBoundingClientRect();
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

  private closeActionPanel(focus: boolean): void {
    const panel = this.actionPanel();
    if (!panel) return;
    drop(panel);
    panel.hidden = true;
    this.unfollowPanel();
    this.actionAnchor = null;
    this.transport.push("masu:action_panel", { open: false });
    if (focus) this.gridEl.focus({ preventScroll: true });
  }

  private unfollowPanel(): void {
    this.panelFollow?.();
    this.panelFollow = null;
  }

  private applyWidths(): void {
    // The row actions' cell is a column of its own, pinned to the end.
    const extra = this.hasRowActions() ? [ROW_ACTIONS_WIDTH] : [];
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
  private load(first: number, last: number, done: () => void): void {
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
    this.on(this.gridEl, "scroll", () => this.onScroll(), { passive: true });
    this.on(this.gridEl, "wheel", (event) => this.onWheel(event as WheelEvent), { passive: false });
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
      const target = event.target as HTMLElement;
      // The boxes: the server holds the selection, the box shows it.
      if (target.closest(".masu-select-all")) {
        event.preventDefault();
        // Every row, unless every row is selected: then none.
        this.chooseAll(!(this.chosen.all && this.chosen.except.size === 0));
        return;
      }
      if (target.closest(".masu-select")) {
        event.preventDefault();
        const cell = this.cellAt(target);
        if (cell) this.onBox(cell.row, event.shiftKey);
        return;
      }
      if (target.closest(".masu-add-row")) {
        event.preventDefault();
        this.addDraft();
        return;
      }
      const more = target.closest<HTMLElement>(".masu-row-actions-button");
      if (more) {
        event.preventDefault();
        const rowEl = more.closest<RowElement>(".masu-row");
        if (rowEl?.masuIndex !== undefined) this.openRowMenu(rowEl.masuIndex, more);
        return;
      }
      const button = target.closest<HTMLElement>(".masu-filter-button");
      if (!button) return;
      const col = Number(button.dataset.col);
      if (this.menu?.col === col) this.closeMenu(true);
      else this.openMenu(col);
    });
    this.on(this.gridEl, "contextmenu", (event) => this.onContextMenu(event));
    this.on(this.el, "contextmenu", (event) => {
      if (performance.now() - this.menuKeyAt < 1000 && (this.cellMenu || this.menu)) event.preventDefault();
    });
    this.on(document, "mousedown", (event) => {
      const panel = this.actionPanel();
      if (panel && !panel.contains(event.target as Node)) this.closeActionPanel(false);
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
    // Focus that leaves the grid (not for its editor or its questions)
    // saves the new row it was on.
    this.on(this.gridEl, "focusout", (event) => {
      const next = (event as FocusEvent).relatedTarget as Node | null;
      if (next && this.el.contains(next)) return;
      setTimeout(() => {
        if (this.editor || this.el.contains(document.activeElement)) return;
        const draft = this.draftAt(this.active.row);
        if (draft) this.saveDrafts([draft.id]);
      }, 0);
    });
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
    const several = additive && this.config.multiSort !== false;
    this.setQuery({ ...this.query, sorts: nextSorts(this.query.sorts, column.key, several) });
  }

  private onKeyDown(event: KeyboardEvent): void {
    const mod = event.ctrlKey || event.metaKey;
    if (this.editor) return;
    // A form editor opens: the keys before it takes the focus are not the grid's.
    if (this.formEditor) {
      event.preventDefault();
      if (event.key === "Escape") this.closeFormEditor(true);
      return;
    }

    // The history of the active cell (Ctrl+Alt+H), with a history.
    if (this.config.history && mod && event.altKey && event.code === "KeyH" && this.active.row >= 0) {
      event.preventDefault();
      this.openHistory(this.active, true);
      return;
    }
    // The menu of the active cell, or of the header.
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
      this.menuKeyAt = performance.now();
      if (this.active.row === -1) {
        if (!this.hasHeaderMenu(this.active.col)) return;
        event.preventDefault();
        this.openMenu(this.active.col);
      } else if (this.openCellMenu(this.active, null)) {
        event.preventDefault();
      }
      return;
    }
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
      rows: this.end(),
      cols: this.columns.length,
      page: this.pageRows(),
      rtl: getComputedStyle(this.gridEl).direction === "rtl",
    });
    if (!target) return;
    event.preventDefault();
    // A page's rows: above its first, the header.
    if (target.row >= 0 && target.row < this.base()) target.row = this.active.row === this.base() ? -1 : this.base();
    // Ctrl+End where the count is not known: it is asked for first.
    if (!this.exact && mod && (event.key === "End" || event.key === "ArrowDown") && !this.countAsked) {
      this.askCount(() => {
        this.active = { row: this.end() - 1, col: target.col };
        this.anchor = null;
        this.ensureVisible(this.active);
        this.render();
      });
      return;
    }

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
    const data = this.dataAt(row);
    if (!data || isDraft(data)) return false;

    // Space on the first column selects the row, or takes it out.
    if (this.config.selection && event.key === " " && col === 0 && !event.altKey && !isGroup(data)) {
      event.preventDefault();
      this.onBox(row, event.shiftKey);
      return true;
    }

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
          const above = this.dataAt(index);
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
    // A right click: the cell under it is the active one, unless it is in
    // the range selected, which its menu is for.
    if (event.button === 2) {
      const cell = this.cellAt(target);
      if (!cell) return;
      this.gridEl.focus({ preventScroll: true });
      const range = this.highlight();
      if (!range || !contains(range, cell.row, cell.col)) {
        this.active = cell;
        this.anchor = null;
        this.render();
      }
      return;
    }
    // A box (the click selects); the focus stays on the grid.
    if (target.closest(".masu-select, .masu-select-all")) {
      event.preventDefault();
      this.gridEl.focus({ preventScroll: true });
      return;
    }
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
    // Ctrl (⌘) and a click selects the row, or takes it out.
    if (this.config.selection && (event.ctrlKey || event.metaKey)) {
      this.active = cell;
      this.anchor = null;
      this.onBox(cell.row, false);
      this.render();
      return;
    }
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
    const wanted = this.config.columnsMenu || this.config.views !== null || (this.config.export ?? []).length > 0;
    if (!wanted && !this.columnsButton && !this.viewsButton && !this.exportButton) return;

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

    // A menu the grid no longer has (an `export` that turned false: the
    // person is no longer an admin, say) goes, with its panel.
    if (!this.config.columnsMenu && this.columnsButton) this.columnsButton = this.dropButton("columns", this.columnsButton);
    if (this.config.views === null && this.viewsButton) this.viewsButton = this.dropButton("views", this.viewsButton);
    if ((this.config.export ?? []).length === 0 && this.exportButton)
      this.exportButton = this.dropButton("export", this.exportButton);

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
    if ((this.config.export ?? []).length > 0 && !this.exportButton) {
      this.exportButton = toolbarButton(this.message("export_menu", {}), "masu-export-button", EXPORT_ICON);
      this.exportButton.addEventListener("click", () => this.togglePanel("export"));
      actions.appendChild(this.exportButton);
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

  private togglePanel(kind: "columns" | "views" | "export"): void {
    const open = this.panel?.kind;
    this.closePanel(false);
    if (open === kind) return;
    this.closeMenu(false);
    const messages = this.messages();

    if (kind === "export") {
      if (this.exportButton?.dataset.busy) return;
      const panel = new ExportPanel(
        {
          root: this.uiEl,
          messages,
          formats: this.config.export ?? [],
          start: (format) => {
            this.closePanel(true);
            this.startExport(format);
          },
          close: () => this.closePanel(true),
        },
        this.exportButton!,
      );
      this.panel = { kind, panel };
    } else if (kind === "columns") {
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
      this.scrollToContent(0);
      this.anchor = null;
      this.active = { row: Math.min(this.active.row, 0), col: Math.min(this.active.col, this.columns.length - 1) };
      this.render();
      this.announceCount();
    });
  }

  private dropButton(kind: "columns" | "views" | "export", button: HTMLButtonElement): null {
    if (this.panel?.kind === kind) this.closePanel(false);
    button.remove();
    return null;
  }

  private closePanel(focus: boolean): void {
    if (!this.panel) return;
    const { kind, panel } = this.panel;
    this.panel = null;
    panel.destroy();
    if (focus) ({ columns: this.columnsButton, views: this.viewsButton, export: this.exportButton })[kind]?.focus();
  }

  // Export (Masu.Export): the server answers with a link, good once, to
  // the file on the router's export route (Masu.Router); the browser
  // downloads it from there as the rows are read, with its own progress.
  // Nothing of the file goes over the socket.

  private startExport(format: string): void {
    const button = this.exportButton;
    if (!button) return;
    button.dataset.busy = "true";
    button.setAttribute("aria-busy", "true");
    this.transport.push("masu:export", { format }, (reply) => {
      delete button.dataset.busy;
      button.removeAttribute("aria-busy");
      if (typeof reply?.url !== "string") {
        this.announce(this.message("export_failed", {}));
        return;
      }
      // A link with `download` downloads where it is, with no tab to open
      // (a pop-up blocker stops a window opened after a round trip).
      const link = document.createElement("a");
      link.href = reply.url;
      link.download = "";
      link.style.display = "none";
      document.body.appendChild(link);
      link.click();
      link.remove();
      this.announce(this.message("export_started", {}));
    });
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

    // A new row: Ctrl+Enter or Insert, or Enter on the row that adds one.
    if (this.config.creates && ((mod && key === "Enter") || (key === "Insert" && !mod && !event.shiftKey))) {
      event.preventDefault();
      this.addDraft();
      return true;
    }
    if (row >= 0 && row === this.addIndex() && (key === "Enter" || key === " ")) {
      event.preventDefault();
      this.addDraft();
      return true;
    }
    // Ctrl+Delete (⌘⌫): the rows of the range, or those selected.
    if (mod && (key === "Delete" || key === "Backspace")) {
      if (!this.config.deletes && !this.draftAt(row)) return false;
      event.preventDefault();
      this.deleteRows();
      return true;
    }
    // Escape on a new row lets it go.
    if (key === "Escape" && !this.anchor && this.draftAt(row)) {
      event.preventDefault();
      this.discardDraft(this.draftAt(row)!.id);
      return true;
    }

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
    const data = this.dataAt(row);
    if (!data || !this.edits(data, col)) return false;

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
    const row = this.dataAt(cell.row);
    if (!column || !row || cell.row < 0 || !this.edits(row, cell.col)) return;
    // An editor of the app's (not for a new row, which has no id yet).
    const own = isDraft(row) ? null : column.editor;
    const factory = own?.kind === "js" ? options.editors?.[own.name] : undefined;
    if (own?.kind === "js" && !factory) console.warn(`Masu: no editor "${own.name}" given to configure({editors})`);
    if (column.type === "boolean" && !own) return;
    const editor = this.people.find((person) => person.editing && person.cell && cellKey(person.cell[0], person.cell[1]) === cellKey(row[0], column.key));
    if (editor) {
      this.announce(this.message("peer_editing", { label: editor.name ?? "" }));
      return;
    }

    this.active = { ...cell };
    this.anchor = null;
    this.ensureVisible(cell);
    const raw = rawValue(row[cell.col + 1]);
    if (own?.kind === "form") return this.openFormEditor(cell, column, row);
    if (own?.kind === "js" && factory) return this.startOwnEdit(cell, column, row, raw, text ?? null, factory, own.options);
    if (column.type === "boolean") return;

    const input = document.createElement("input");
    input.className = `masu-editor masu-align-${column.align}`;
    input.type = column.type === "date" ? "date" : column.type === "datetime" ? "datetime-local" : column.type === "time" ? "time" : "text";
    if (input.type !== "text") input.step = "1";
    if (column.type === "integer" || column.type === "number" || column.type === "decimal") input.inputMode = "decimal";
    input.setAttribute("aria-label", column.label);
    input.value = text ?? inputText(column.type, raw);
    input.style.transform = `translateY(${this.rowY(cell.row)}px)`;
    input.style.insetInlineStart = `${this.colLeft(cell.col)}px`;
    input.style.width = `${this.widths[cell.col]}px`;
    input.style.height = `${this.config.rowHeight}px`;

    this.editor = { input, el: input, own: null, row: cell.row, col: cell.col, id: row[0], original: raw, done: false, list: null, options: [], shown: [], highlight: -1 };
    input.addEventListener("keydown", (event) => this.onEditorKey(event));
    input.addEventListener("blur", () => this.commitEdit(null, true));
    this.body.appendChild(input);
    if (column.type === "enum") this.openChoices(this.editor, column, text !== undefined);
    input.focus();
    if (text === undefined && input.type === "text") input.setSelectionRange(input.value.length, input.value.length);
    this.reportCursor();
  }

  /**
   * An editor of the app's (`configure({editors})`): it draws in a box over
   * the cell, and commits or cancels; the grid keeps Enter, Tab and Escape
   * (unless the editor prevents them), the focus that leaves it, and the
   * rest of an edit.
   */
  private startOwnEdit(
    cell: Cell,
    column: ColumnConfig,
    row: Row,
    raw: CellValue,
    text: string | null,
    factory: CellEditorFactory,
    editorOptions: Record<string, unknown>,
  ): void {
    const box = document.createElement("div");
    box.className = `masu-editor masu-own-editor masu-align-${column.align}`;
    box.style.transform = `translateY(${this.rowY(cell.row)}px)`;
    box.style.insetInlineStart = `${this.colLeft(cell.col)}px`;
    box.style.width = `${this.widths[cell.col]}px`;
    box.style.minHeight = `${this.config.rowHeight}px`;
    this.body.appendChild(box);

    const input = document.createElement("input");
    const editor: Editor = { input, el: box, own: null, row: cell.row, col: cell.col, id: row[0], original: raw, done: false, list: null, options: [], shown: [], highlight: -1 };
    this.editor = editor;
    const values = Object.fromEntries(this.columns.map((c, col) => [c.key, rawValue(row[col + 1])]));
    editor.own = factory({
      element: box,
      value: raw,
      text,
      id: row[0],
      row: values,
      column,
      options: editorOptions,
      label: column.label,
      locale: this.config.locale ?? null,
      commit: (value, move) => {
        if (this.editor === editor) this.commitOwn(value, move ? MOVES[move] : null, false);
      },
      cancel: () => {
        if (this.editor === editor) this.closeEditor();
      },
    });

    box.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.defaultPrevented || this.editor !== editor) return;
      const value = () => (editor.own?.value ? editor.own.value() : editor.original);
      if (event.key === "Escape") {
        event.preventDefault();
        this.closeEditor();
      } else if (event.key === "Enter" && !event.altKey) {
        event.preventDefault();
        this.commitOwn(value(), { row: event.shiftKey ? -1 : 1, col: 0 }, false);
      } else if (event.key === "Tab") {
        event.preventDefault();
        this.commitOwn(value(), { row: 0, col: event.shiftKey ? -1 : 1 }, false);
      }
    });
    // The focus that leaves the editor (and what it put elsewhere) commits.
    box.addEventListener("focusout", () => {
      setTimeout(() => {
        const now = document.activeElement;
        if (this.editor !== editor || (now && (box.contains(now) || editor.own?.contains?.(now)))) return;
        this.commitEdit(null, true);
      }, 0);
    });

    if (editor.own.focus) editor.own.focus();
    else (box.querySelector<HTMLElement>(FOCUSABLE) ?? box).focus();
    this.reportCursor();
  }

  /** Saves the value of an editor of the app's, checked by the column's type, and moves. */
  private commitOwn(value: CellValue, step: { row: number; col: number } | null, blur: boolean): void {
    const editor = this.editor;
    if (!editor || editor.done) return;
    const column = this.columns[editor.col];
    const changed = JSON.stringify(value ?? null) !== JSON.stringify(editor.original ?? null);
    const problem = changed && typeof value !== "number" ? invalid(column.type, value as string | boolean | null, column.values) : null;
    if (problem && !blur) {
      this.announce(`${column.label}: ${this.message(problem, {})}`);
      return;
    }
    this.closeEditor();
    if (problem) {
      this.announce(`${column.label}: ${this.message(problem, {})} ${this.message("not_saved", {})}`);
      return;
    }
    const sent = typeof value === "number" ? String(value) : (value as string | boolean | null);
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value: sent, before: editor.original }]);
    if (step) {
      this.active = {
        row: Math.min(Math.max(editor.row + step.row, 0), this.rowCount() - 1),
        col: Math.min(Math.max(editor.col + step.col, 0), this.columns.length - 1),
      };
      this.ensureVisible(this.active);
      this.render();
    }
  }

  /**
   * An editor that is a form of the app's: the server renders it (the
   * column's `editor` function) in a popover under the cell, with the
   * cell's value as the row has it now. What its form posts is the new
   * value.
   */
  private openFormEditor(cell: Cell, column: ColumnConfig, row: Row): void {
    this.closeFormEditor(false);
    this.closeActionPanel(false);
    const editor: FormEditor = { row: cell.row, col: cell.col, id: row[0], key: column.key, version: null, initial: undefined, wired: false, done: false };
    this.formEditor = editor;
    this.render();
    this.reportCursor();
    this.transport.push("masu:cell_editor", { id: row[0], key: column.key }, (reply) => {
      if (this.formEditor !== editor) return;
      if (typeof reply.version !== "number") {
        this.formEditor = null;
        this.reportCursor();
        this.announce(this.message("not_editable", { count: 1 }));
        return;
      }
      editor.version = reply.version;
      this.placeFormEditor();
    });
  }

  /** The popover of the form editor, as the server rendered it. */
  private formEditorEl(): HTMLElement | null {
    return this.el.querySelector<HTMLElement>(":scope > .masu-panels > .masu-cell-editor");
  }

  /** Places the form editor's popover under its cell, and wires it the first time. */
  private placeFormEditor(): void {
    const editor = this.formEditor;
    const popover = this.formEditorEl();
    if (!editor || !popover || popover.dataset.key !== editor.key) {
      this.formFollow?.();
      this.formFollow = null;
      return;
    }
    const target = this.cellElement({ row: editor.row, col: editor.col });
    const box = (target ?? this.gridEl).getBoundingClientRect();
    if (floats(popover)) {
      lift(popover);
      placeAt(popover, { left: box.left, below: box.bottom + 4, above: box.top - 4 }, (name, value) => setStyle(popover, name, value));
      this.formFollow ??= follow(() => this.placeFormEditor());
    } else {
      const root = this.el.getBoundingClientRect();
      setStyle(popover, "top", `${box.bottom - root.top + 4}px`);
      setStyle(popover, "inset-inline-start", `${Math.max(0, Math.min(box.left - root.left, root.width - popover.offsetWidth))}px`);
    }
    if (editor.wired) return;
    editor.wired = true;

    const form = popover.querySelector<HTMLFormElement>("form")!;
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      this.commitForm(editor);
    });
    // Ctrl+Enter (⌘↩) saves, before the editor's own keys (a rich text
    // editor takes it otherwise); Escape is the editor's first (its own
    // calendar closes), then the grid's.
    popover.addEventListener(
      "keydown",
      (event) => {
        if (event.key !== "Enter" || !(event.ctrlKey || event.metaKey)) return;
        event.preventDefault();
        event.stopPropagation();
        this.commitForm(editor);
      },
      { capture: true },
    );
    popover.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      this.closeFormEditor(true);
    });
    // The focus that leaves the popover (a click away) commits.
    popover.addEventListener("focusout", () => {
      setTimeout(() => {
        const now = document.activeElement;
        if (this.formEditor !== editor || (now && popover.contains(now))) return;
        this.commitForm(editor, false);
      }, 0);
    });
    // What it posts when it opened (the values the server rendered in it).
    editor.initial = formValue(form);
    (popover.querySelector<HTMLElement>(FOCUSABLE) ?? popover).focus();
  }

  /** Saves what the form posts, when it changed, and closes the popover. */
  private commitForm(editor: FormEditor, focus = true): void {
    if (this.formEditor !== editor || editor.done) return;
    const form = this.formEditorEl()?.querySelector<HTMLFormElement>("form");
    const value = form ? formValue(form) : undefined;
    editor.done = true;
    this.closeFormEditor(focus);
    if (value === undefined || editor.initial === undefined || JSON.stringify(value) === JSON.stringify(editor.initial)) return;
    const data = this.dataAt(editor.row);
    const before = data && data[0] === editor.id ? rawValue(data[editor.col + 1]) : null;
    this.send([{ id: editor.id, key: editor.key, col: editor.col, row: editor.row, before, value, form: { before: editor.initial, version: editor.version } }], "edit", "edit");
  }

  private closeFormEditor(focus: boolean): void {
    if (!this.formEditor) return;
    this.formEditor = null;
    this.formFollow?.();
    this.formFollow = null;
    const popover = this.formEditorEl();
    if (popover) {
      drop(popover);
      popover.hidden = true;
    }
    this.transport.push("masu:cell_editor", { open: false });
    this.reportCursor();
    if (focus) this.gridEl.focus({ preventScroll: true });
  }

  /**
   * An enum's editor: a list of its values under the cell (or above, at
   * the bottom of the grid), which narrows as the person types; ↑ and ↓
   * pick, Enter takes. The values are the column's own (`values`), or the
   * values its rows have (as its filter menu has them).
   */
  private openChoices(editor: Editor, column: ColumnConfig, typed: boolean): void {
    const list = document.createElement("ul");
    const listId = `${this.id}-choices`;
    list.id = listId;
    list.className = "masu-choices";
    list.setAttribute("role", "listbox");
    list.setAttribute("aria-label", column.label);
    editor.list = list;
    const input = editor.input;
    input.setAttribute("role", "combobox");
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-controls", listId);
    input.setAttribute("aria-expanded", "true");
    input.autocomplete = "off";

    // Where it opens: under the cell, or above it when the screen ends.
    const top = this.rowY(editor.row);
    const room = this.gridEl.scrollTop + this.gridEl.clientHeight - (top + this.config.rowHeight + this.head.offsetHeight);
    list.style.insetInlineStart = `${this.colLeft(editor.col)}px`;
    list.style.minWidth = `${this.widths[editor.col]}px`;
    if (room < 200 && top - this.gridEl.scrollTop > room) {
      list.style.transform = `translateY(calc(${top}px - 100%))`;
    } else {
      list.style.transform = `translateY(${top + this.config.rowHeight}px)`;
    }
    // A click on a value takes it (before the input's blur).
    list.addEventListener("mousedown", (event) => {
      const option = (event.target as HTMLElement).closest<HTMLElement>("[data-index]");
      if (!option) return;
      event.preventDefault();
      editor.input.value = editor.shown[Number(option.dataset.index)] ?? editor.input.value;
      this.commitEdit({ row: 0, col: 0 });
    });
    input.addEventListener("input", () => this.showChoices(editor, true));
    this.body.appendChild(list);

    const show = (values: CellValue[]) => {
      if (this.editor !== editor) return;
      editor.options = values.filter((value) => value !== null).map((value) => String(value));
      this.showChoices(editor, typed);
    };
    if (column.values && column.values.length > 0) show(column.values);
    else
      this.transport.push("masu:values", { key: column.key }, (reply) => {
        show(((reply.values as [CellValue, number][]) ?? []).map(([value]) => value));
      });
  }

  /** The values that match the editor's text; the first is picked when the person typed. */
  private showChoices(editor: Editor, typed: boolean): void {
    if (!editor.list) return;
    const text = editor.input.value;
    editor.shown = typed ? matching(editor.options, text) : editor.options;
    editor.highlight = typed ? (editor.shown.length > 0 && text.trim() !== "" ? 0 : -1) : editor.shown.indexOf(text);
    const items = editor.shown.map((value, index) => {
      const item = document.createElement("li");
      item.id = `${this.id}-choice-${index}`;
      item.className = "masu-choice";
      item.setAttribute("role", "option");
      item.dataset.index = String(index);
      item.textContent = value;
      return item;
    });
    editor.list.replaceChildren(...items);
    editor.list.hidden = items.length === 0;
    this.highlightChoice(editor);
  }

  private highlightChoice(editor: Editor): void {
    if (!editor.list) return;
    editor.list.querySelectorAll<HTMLElement>(".masu-choice").forEach((item, index) => {
      item.setAttribute("aria-selected", String(index === editor.highlight));
    });
    const current = editor.highlight >= 0 ? editor.list.children[editor.highlight] : null;
    if (current) {
      editor.input.setAttribute("aria-activedescendant", current.id);
      (current as HTMLElement).scrollIntoView?.({ block: "nearest" });
    } else {
      editor.input.removeAttribute("aria-activedescendant");
    }
  }

  private onEditorKey(event: KeyboardEvent): void {
    event.stopPropagation();
    const editor = this.editor;
    // An enum's list: ↑ and ↓ pick a value, Enter and Tab take it.
    if (editor?.list && editor.shown.length > 0) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const step = event.key === "ArrowDown" ? 1 : -1;
        editor.highlight = (editor.highlight + step + editor.shown.length) % editor.shown.length;
        this.highlightChoice(editor);
        return;
      }
      if ((event.key === "Enter" || event.key === "Tab") && editor.highlight >= 0) {
        editor.input.value = editor.shown[editor.highlight];
      }
    }
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

  private commitEdit(step: { row: number; col: number } | null, blur = false): void {
    const editor = this.editor;
    if (!editor || editor.done) return;
    if (editor.own) {
      // The focus left an editor of the app's: its value as it is, if it says.
      if (editor.own.value) this.commitOwn(editor.own.value(), step, blur);
      else this.closeEditor();
      return;
    }
    const column = this.columns[editor.col];
    const changed = editor.input.value !== inputText(column.type, editor.original);
    const value = sendValue(column.type, editor.input.value, this.config.locale ?? undefined);
    // A value the server would refuse (text in a number): the editor stays,
    // and says so; leaving it lets the value go.
    const problem = changed ? invalid(column.type, value, column.values) : null;
    if (problem && !blur) {
      editor.input.setAttribute("aria-invalid", "true");
      editor.input.title = this.message(problem, {});
      this.announce(`${column.label}: ${this.message(problem, {})}`);
      return;
    }
    editor.done = true;
    this.closeEditor();
    if (problem) {
      this.announce(`${column.label}: ${this.message(problem, {})} ${this.message("not_saved", {})}`);
      return;
    }
    // The value the person saw is the one the editor opened with: a save
    // by someone else while they typed is a conflict, not their base.
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value, before: editor.original }]);
    if (step) {
      this.active = {
        row: Math.min(Math.max(editor.row + step.row, 0), this.rowCount() - 1),
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
    editor.own?.destroy?.();
    editor.el.remove();
    editor.list?.remove();
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
    origin: "edit" | "paste" | "fill" | "clear" = "edit",
  ): void {
    const edits: Edit[] = [];
    let skipped = 0;
    let drafted = false;
    let firstProblem: string | null = null;
    for (const { row, col, value, before: seen } of cells) {
      const column = this.columns[col];
      const data = this.dataAt(row);
      if (!column || !data || !this.edits(data, col)) {
        skipped += 1;
        continue;
      }
      // A value the server would refuse stays out, with its error.
      const problem = invalid(column.type, value, column.values);
      if (problem) {
        this.errors.set(cellKey(data[0], column.key), this.message(problem, {}));
        firstProblem ??= `${column.label}: ${this.message(problem, {})}`;
        continue;
      }
      // A new row keeps its values until it saves.
      const draft = this.draftAt(row);
      if (draft) {
        this.setDraftValue(draft, column.key, value);
        drafted = true;
        continue;
      }
      const before = seen !== undefined ? seen : rawValue(data[col + 1]);
      edits.push({ id: data[0], key: column.key, col, row, before, value });
      this.setValue(row, col, column.html ? [escapeHTML(String(value ?? "")), shownValue(column.type, value)] : shownValue(column.type, value));
    }
    if (skipped > 0) this.announce(this.message("not_editable", { count: skipped }));
    if (firstProblem) this.announce(firstProblem);
    if (drafted || firstProblem) this.refreshRows();
    this.send(edits, "edit", origin);
  }

  private send(edits: Edit[], mode: "edit" | "undo" | "redo", origin: string = mode): void {
    if (edits.length === 0) return;
    for (const edit of edits) {
      const key = cellKey(edit.id, edit.key);
      this.errors.delete(key);
      this.saving.add(key);
    }
    this.refreshRows();

    // Each edit says what the person saw: the server refuses it when the
    // cell changed meanwhile (see Masu.Edit).
    // A form's edit says the version of the value it opened with instead.
    const payload = edits.map((edit) =>
      edit.form ? { id: edit.id, key: edit.key, value: edit.value, version: edit.form.version ?? undefined } : { id: edit.id, key: edit.key, value: edit.value, before: edit.before },
    );
    this.inFlight++;
    this.transport.push("masu:edit", { edits: payload, origin }, (reply) => {
      this.inFlight--;
      const errors = (reply.errors as [unknown, string, string, CellValue?][]) ?? [];
      // Cells saved later (Masu.Write.async/1) stay saving until the reply.
      const later = new Set(((reply.saving as [unknown, string][]) ?? []).map(([id, key]) => cellKey(id, key)));
      const now = edits.filter((edit) => !later.has(cellKey(edit.id, edit.key)));
      if (typeof reply.async === "string" && later.size > 0) {
        this.later.set(reply.async, { kind: "edits", edits: edits.filter((edit) => later.has(cellKey(edit.id, edit.key))), mode });
        if (errors.length === 0) this.announce(this.message("saving_later", {}));
      }
      if (now.length > 0 || errors.length > 0) this.takeEditReply(now, errors, mode);
      else this.refreshRows();
    });
  }

  /** The answer to edits: the cells refused show their old values (or their values now), with their errors. */
  private takeEditReply(edits: Edit[], errors: [unknown, string, string, CellValue?][], mode: "edit" | "undo" | "redo"): void {
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
      // A form's edit did not change the cell it shows: it stays as it is.
      if (refusal && !edit.form && edit.row !== undefined && this.valueAt(edit.row, edit.col) !== undefined) {
        const column = this.columns[edit.col];
        const value = refusal.now ? refusal.value : edit.before;
        this.setValue(edit.row, edit.col, column.html ? [escapeHTML(String(value ?? "")), value] : value);
      }
    }

    const saved = edits.filter((edit) => !refused.has(cellKey(edit.id, edit.key)));
    if (saved.length > 0) {
      if (mode === "undo") this.redoStack.push({ kind: "edits", edits: saved });
      else {
        this.undoStack.push({ kind: "edits", edits: saved });
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

    // An undo (or a redo) that came before this answer: it takes back this
    // edit now; or none, when the server refused the edit.
    if (this.inFlight === 0 && this.waiting.length > 0) {
      const waiting = this.waiting;
      this.waiting = [];
      if (saved.length > 0) for (const step of waiting) step === "undo" ? this.undo() : this.redo();
    }
  }

  private undo(): void {
    if (this.undoStack.length === 0 && this.inFlight > 0) {
      this.waiting.push("undo");
      return;
    }
    const step = this.undoStack.pop();
    if (step?.kind === "edits") this.send(step.edits.map((edit) => this.reverse(edit)), "undo");
    else if (step?.kind === "delete") this.restoreRows(step.undo);
  }

  private redo(): void {
    if (this.redoStack.length === 0 && this.inFlight > 0) {
      this.waiting.push("redo");
      return;
    }
    const step = this.redoStack.pop();
    if (step?.kind === "edits") this.send(step.edits.map((edit) => this.reverse(edit)), "redo");
    else if (step?.kind === "restore") this.pushDelete({ ids: step.ids }, true);
  }

  /** The edit that takes `edit` back. */
  private reverse(edit: Edit): Edit {
    // A form's edit: back to what the form posted when it opened.
    if (edit.form) return { ...edit, value: edit.form.before, row: undefined, form: { before: edit.value, version: null } };
    const column = this.columns[edit.col];
    const value = edit.before === null ? null : typeof edit.before === "boolean" ? edit.before : sendValue(column.type, inputText(column.type, edit.before), undefined);
    return { ...edit, before: shownValue(column.type, edit.value as string | boolean | null), value, row: undefined };
  }

  private clearCells(): void {
    const selection = this.selection();
    if (!selection) return;
    this.withRows(selection, (cells) => this.applyEdits(cells.map(({ row, col }) => ({ row, col, value: null })), "clear"));
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
      this.applyEdits(edits, "fill");
    });
  }

  private onPaste(event: ClipboardEvent): void {
    if (document.activeElement !== this.gridEl || this.editor) return;
    const text = event.clipboardData?.getData("text/plain");
    if (!text) return;
    event.preventDefault();
    const selection = this.selection() ?? { top: 0, left: 0, bottom: 0, right: 0 };
    const matrix = fromTSV(text);
    // On the new rows: their values, and more new rows for more lines.
    if (selection.top >= this.span() && this.config.creates) {
      this.pasteIntoDrafts(matrix, selection);
      return;
    }
    // Lines past the last row: new rows, if the person wants them.
    const single = matrix.length === 1 && matrix[0].length === 1;
    const overflow = single || !this.exact ? 0 : Math.min(matrix.length - (this.total - selection.top), MAX_NEW_ROWS);
    if (overflow > 0 && this.config.creates) {
      this.confirm(this.message("paste_add", { count: overflow }), this.message("add_rows", {}), () =>
        this.addPastedRows(matrix.slice(matrix.length - overflow), selection.left),
      );
    }
    const placed = placePaste(matrix, selection, this.span(), this.columns.length).slice(0, MAX_EDITS);
    if (placed.length === 0) return;
    const bottom = Math.max(...placed.map((p) => p.row));
    const right = Math.max(...placed.map((p) => p.col));
    this.anchor = { row: selection.top, col: selection.left };
    this.active = { row: bottom, col: right };
    this.load(selection.top, bottom, () => {
      const locale = this.config.locale ?? undefined;
      this.applyEdits(
        placed.map((p) => ({ row: p.row, col: p.col, value: sendValue(this.columns[p.col].type, p.text, locale) })),
        "paste",
      );
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
    if (isDraft(data)) return !this.columns[col]?.creatable;
    if (!this.config.locks) return false;
    const lock = (data as unknown[])[this.columns.length + 1];
    return lock === true || (Array.isArray(lock) && lock.includes(col));
  }

  private valueAt(row: number, col: number): CellValue | undefined {
    const data = this.dataAt(row);
    return data ? rawValue(data[col + 1]) : undefined;
  }

  /** Puts a value in a row the browser has, in a new copy of the row. */
  private setValue(row: number, col: number, value: unknown): void {
    if (this.draftAt(row)) return;
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

  // New rows (`create`): a row that adds one after the rows of the query,
  // and the new rows, drafts until they save. A draft saves when the
  // person leaves it (another row, or out of the grid), and stays with
  // its errors on its cells when the server refuses it. Escape lets it go.

  /** The rows the grid draws: the query's, the drafts, the row that adds one. */
  private rowCount(): number {
    return this.span() + this.drafts.length + (this.config.creates ? 1 : 0);
  }

  /** The index of the row that adds one, or -1. */
  private addIndex(): number {
    return this.config.creates ? this.span() + this.drafts.length : -1;
  }

  /** The row at an index: the query's (as the browser has it), or a draft's. */
  private dataAt(index: number): Row | undefined {
    if (index < this.span()) return this.cache.get(index) ?? this.stale?.get(index);
    return this.drafts[index - this.span()]?.row;
  }

  private draftAt(index: number): Draft | undefined {
    return index >= this.span() ? this.drafts[index - this.span()] : undefined;
  }

  /**
   * The rows of the query the grid scrolls over: its count, or, while the
   * count is not known, the rows read and a block more (a page more), which
   * grow as blocks come back full.
   */
  private span(): number {
    if (this.exact) return this.total;
    return this.paged() ? Math.max(this.total, this.base() + this.config.pageSize) : this.total + GROW;
  }

  private paged(): boolean {
    return this.config.paging === "pages";
  }

  /** The first row the body holds: 0, or the page's first. */
  private base(): number {
    return this.paged() ? this.config.page * this.config.pageSize : 0;
  }

  /** The index after the last row the body holds: every row's, or the page's (the last page with the new rows). */
  private end(): number {
    const count = this.rowCount();
    if (!this.paged()) return count;
    const pageEnd = this.base() + this.config.pageSize;
    return this.exact && pageEnd >= this.total ? count : Math.min(pageEnd, count);
  }

  /** The open details of the rows the body holds, by their place in it. */
  private localGaps(): Gap[] {
    const base = this.base();
    if (base === 0 && !this.paged()) return this.gaps;
    const end = this.end();
    return this.gaps.filter((gap) => gap.index >= base && gap.index < end).map((gap) => ({ index: gap.index - base, height: gap.height }));
  }

  /** Asks the server for the count (once a revision), then `then`. */
  private askCount(then?: () => void): void {
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
  private edits(data: Row, col: number): boolean {
    const column = this.columns[col];
    if (!column) return false;
    if (isDraft(data)) return column.creatable === true;
    return column.editable === true && !this.locked(data, col);
  }

  /**
   * A new count of the query's rows, which moves the drafts: the active
   * cell stays on the draft, or the row that adds one, it was on.
   */
  private setTotal(total: number, exact = this.exact): void {
    const draft = this.draftAt(this.active.row);
    const adding = this.active.row >= 0 && this.active.row === this.addIndex();
    this.total = total;
    this.exact = exact;
    if (draft) this.active = { row: this.span() + this.drafts.indexOf(draft), col: this.active.col };
    else if (adding) this.active = { row: this.addIndex(), col: this.active.col };
  }

  /** Takes drafts out, keeping the active cell on what it was on. */
  private dropDrafts(ids: Set<string>): void {
    const draft = this.draftAt(this.active.row);
    const adding = this.active.row >= 0 && this.active.row === this.addIndex();
    for (const d of this.drafts) {
      if (!ids.has(d.id)) continue;
      for (const column of this.columns) this.errors.delete(cellKey(d.id, column.key));
    }
    this.drafts = this.drafts.filter((d) => !ids.has(d.id));
    if (draft && !ids.has(draft.id)) this.active = { row: this.span() + this.drafts.indexOf(draft), col: this.active.col };
    else if (draft || adding) this.active = { row: Math.max(0, Math.min(this.addIndex(), this.rowCount() - 1)), col: this.active.col };
    this.activeDraft = this.draftAt(this.active.row)?.id ?? null;
    this.anchor = null;
    this.clearRows();
  }

  private draftRow(draft: Draft): Row {
    return [draft.id, ...this.columns.map((column) => shownValue(column.type, draft.values.get(column.key) ?? null))] as Row;
  }

  private setDraftValue(draft: Draft, key: string, value: string | boolean | null): void {
    if (value === null || value === "") draft.values.delete(key);
    else draft.values.set(key, value);
    this.errors.delete(cellKey(draft.id, key));
    draft.row = this.draftRow(draft);
  }

  private newDraft(): Draft {
    const draft: Draft = { id: `${DRAFT}${++this.draftCount}`, values: new Map(), row: [null] as unknown as Row, saving: false };
    draft.row = this.draftRow(draft);
    return draft;
  }

  /** A new row, under the others; the one the person was on saves. */
  private addDraft(): void {
    if (!this.config.creates) return;
    // In a grid of pages, new rows are on the last page: it goes there first.
    if (this.paged() && this.end() < this.rowCount()) {
      if (this.toLastPage) return;
      this.toLastPage = true;
      this.askCount(() => {
        const last = Math.max(0, Math.ceil(this.total / this.config.pageSize) - 1);
        this.transport.push("masu:page", { page: last }, () => {
          // The page comes with the server's render; the new row after it.
          setTimeout(() => {
            this.toLastPage = false;
            if (this.end() === this.rowCount()) this.addDraft();
          }, 0);
        });
      });
      return;
    }
    const current = this.draftAt(this.active.row);
    if (current) this.saveDrafts([current.id]);
    const draft = this.newDraft();
    this.drafts.push(draft);
    const editable = this.columns.findIndex((column) => column.creatable);
    const col = this.columns[this.active.col]?.creatable ? this.active.col : Math.max(0, editable);
    this.active = { row: this.span() + this.drafts.length - 1, col };
    this.activeDraft = draft.id;
    this.anchor = null;
    this.gridEl.focus({ preventScroll: true });
    this.ensureVisible(this.active);
    this.render();
    this.announce(this.message("new_row", {}));
  }

  private discardDraft(id: string): void {
    this.dropDrafts(new Set([id]));
    this.render();
    this.announce(this.message("draft_discarded", {}));
  }

  /** The active cell left a draft: it saves. */
  private leaveDraft(): void {
    const now = this.draftAt(this.active.row)?.id ?? null;
    const left = this.activeDraft;
    this.activeDraft = now;
    if (left && left !== now && !this.editor) setTimeout(() => this.saveDrafts([left]), 0);
  }

  /**
   * Saves drafts (`masu:create`): a saved one leaves the drafts (its row
   * comes in the query's rows, with a flash); a refused one stays, with
   * its errors on its cells. An empty draft just goes.
   */
  private saveDrafts(ids: string[], showRefused = false): void {
    const wanted = new Set(ids);
    const drafts = this.drafts.filter((d) => wanted.has(d.id) && !d.saving);
    const empty = drafts.filter((d) => d.values.size === 0);
    if (empty.length > 0) {
      this.dropDrafts(new Set(empty.map((d) => d.id)));
      this.render();
    }
    const saving = drafts.filter((d) => d.values.size > 0);
    if (saving.length === 0) return;
    for (const draft of saving) {
      draft.saving = true;
      for (const key of draft.values.keys()) this.saving.add(cellKey(draft.id, key));
    }
    this.refreshRows();

    const rows = saving.map((draft) => Object.fromEntries(draft.values));
    this.transport.push("masu:create", { rows, origin: showRefused ? "paste" : "draft" }, (reply) => {
      for (const draft of saving) {
        draft.saving = false;
        for (const key of draft.values.keys()) this.saving.delete(cellKey(draft.id, key));
      }
      if (typeof reply.error === "string") {
        this.announce(reply.error);
        this.refreshRows();
        return;
      }
      const results = (reply.results as { id?: unknown; errors?: [string | null, string][] }[]) ?? [];
      const saved = new Set<string>();
      const now = performance.now();
      let firstError: string | null = null;
      results.forEach((result, i) => {
        const draft = saving[i];
        if (!draft) return;
        if (result.errors) {
          for (const [key, message] of result.errors) {
            const column = this.columns.find((c) => c.key === key) ?? this.columns[0];
            this.errors.set(cellKey(draft.id, column.key), message);
            firstError ??= `${column.label}: ${message}`;
          }
          draft.row = this.draftRow(draft);
        } else {
          saved.add(draft.id);
          this.flash.set(String(result.id), { until: now + FLASH, color: undefined });
        }
      });
      if (saved.size > 0) this.dropDrafts(saved);
      if (typeof reply.total === "number") this.setTotal(reply.total);
      // New rows of a paste that the server refused: the first is shown.
      const refused = saving.find((draft) => !saved.has(draft.id));
      if (showRefused && refused) {
        const col = this.columns.findIndex((column) => this.errors.has(cellKey(refused.id, column.key)));
        this.active = { row: this.span() + this.drafts.indexOf(refused), col: Math.max(0, col) };
        this.activeDraft = refused.id;
        this.anchor = null;
        this.ensureVisible(this.active);
      }
      this.refreshRows();

      if (firstError) this.announce(firstError);
      else if (saved.size > 1) this.announce(this.message("rows_added", { count: saved.size }));
      else if (saved.size === 1) this.announce(this.message(reply.index === null ? "row_added_hidden" : "row_added", {}));
    });
  }

  /** Lines of a paste on the new rows: their values, and more new rows. */
  private pasteIntoDrafts(matrix: string[][], selection: Rect): void {
    const first = selection.top - this.span();
    const lines = matrix.slice(0, MAX_NEW_ROWS);
    while (this.drafts.length < first + lines.length) this.drafts.push(this.newDraft());
    this.fillDrafts(this.drafts.slice(first, first + lines.length), lines, selection.left);
    this.anchor = { row: selection.top, col: selection.left };
    this.active = { row: selection.top + lines.length - 1, col: Math.min(selection.left + Math.max(...lines.map((l) => l.length)) - 1, this.columns.length - 1) };
    this.activeDraft = this.draftAt(this.active.row)?.id ?? null;
    this.clearRows();
    this.render();
  }

  /** The lines of a paste past the last row, as new rows, saved at once. */
  private addPastedRows(lines: string[][], left: number): void {
    const drafts = lines.map(() => this.newDraft());
    this.drafts.push(...drafts);
    this.fillDrafts(drafts, lines, left);
    this.render();
    this.saveDrafts(
      drafts.map((d) => d.id),
      true,
    );
  }

  private fillDrafts(drafts: Draft[], lines: string[][], left: number): void {
    const locale = this.config.locale ?? undefined;
    drafts.forEach((draft, r) => {
      lines[r].forEach((text, c) => {
        const column = this.columns[left + c];
        if (column?.creatable) this.setDraftValue(draft, column.key, sendValue(column.type, text, locale));
      });
    });
  }

  // Deleting rows (`delete`, `deletable`): Ctrl+Delete on a range, or the
  // rows selected, after a question; Ctrl+Z brings them back when the
  // grid can.

  private deleteRows(): void {
    // The rows selected with their boxes, when there are.
    if (this.config.selection && this.chosen.count > 0) {
      this.confirmDelete(this.chosen.count, { selection: true });
      return;
    }
    const range = this.selection();
    if (!range) return;
    // New rows in the range just go.
    const drafts = new Set<string>();
    for (let index = Math.max(range.top, this.span()); index <= range.bottom; index++) {
      const draft = this.draftAt(index);
      if (draft) drafts.add(draft.id);
    }
    if (drafts.size > 0) this.discardDrafts(drafts);
    if (!this.config.deletes || range.top >= this.span()) return;
    const bottom = Math.min(range.bottom, this.span() - 1, range.top + MAX_NEW_ROWS - 1);
    this.load(range.top, bottom, () => {
      const ids: unknown[] = [];
      for (let index = range.top; index <= bottom; index++) {
        const row = this.cache.get(index);
        if (row && !isGroup(row)) ids.push(row[0]);
      }
      if (ids.length > 0) this.confirmDelete(ids.length, { ids });
    });
  }

  private discardDrafts(ids: Set<string>): void {
    this.dropDrafts(ids);
    this.render();
    this.announce(this.message("draft_discarded", {}));
  }

  private confirmDelete(count: number, payload: { ids: unknown[] } | { selection: true }): void {
    const question = count === 1 ? this.message("delete_one", {}) : this.message("delete_rows", { count });
    this.confirm(question, this.message("delete", {}), () => this.pushDelete(payload, false), true);
  }

  /** Deletes rows; the step goes on the undo stack (or, for a redo, back on it). */
  private pushDelete(payload: { ids: unknown[] } | { selection: true }, redo: boolean): void {
    const origin = redo ? "redo" : "selection" in payload ? "selection" : "rows";
    this.transport.push("masu:delete", { ...payload, origin }, (reply) => {
      if (typeof reply.error === "string") {
        this.announce(reply.error);
        return;
      }
      // Rows deleted later (Masu.Write.async/1): the reply says how it went.
      const later = (reply.saving as unknown[]) ?? [];
      if (typeof reply.async === "string" && later.length > 0) {
        this.later.set(reply.async, { kind: "delete", count: later.length });
        if (((reply.deleted as number) ?? 0) === 0) {
          this.announce(this.message("deleting_later", {}));
          return;
        }
      }
      const deleted = (reply.deleted as number) ?? 0;
      const errors = (reply.errors as [unknown, string][]) ?? [];
      if (typeof reply.total === "number") this.setTotal(reply.total);
      this.anchor = null;
      if (deleted > 0 && typeof reply.undo === "string") {
        this.undoStack.push({ kind: "delete", undo: reply.undo });
        if (!redo) this.redoStack = [];
      }
      const said = deleted === 1 ? this.message("deleted_one", {}) : this.message("deleted", { count: deleted });
      this.announce(errors.length > 0 ? `${deleted > 0 ? `${said} ` : ""}${errors[0][1]}` : said);
      this.render();
    });
  }

  /** Brings back the rows of a delete (Ctrl+Z); a redo deletes them again. */
  private restoreRows(undo: string): void {
    this.transport.push("masu:restore", { undo }, (reply) => {
      if (typeof reply.error === "string") {
        this.announce(reply.error);
        return;
      }
      const ids = (reply.ids as unknown[]) ?? [];
      if (typeof reply.total === "number") this.setTotal(reply.total);
      const now = performance.now();
      for (const id of ids) this.flash.set(String(id), { until: now + FLASH, color: undefined });
      if (ids.length > 0) this.redoStack.push({ kind: "restore", ids });
      this.announce(ids.length === 1 ? this.message("restored_one", {}) : this.message("restored", { count: ids.length }));
      this.render();
    });
  }

  /**
   * A question above the grid, with its answer and Cancel; the answer has
   * the focus, Escape cancels, and the focus goes back to the grid.
   */
  private confirm(question: string, answer: string, then: () => void, danger = false): void {
    this.confirmEl?.remove();
    const el = document.createElement("div");
    el.className = "masu-confirm";
    el.setAttribute("role", "alertdialog");
    el.setAttribute("aria-label", question);
    const text = document.createElement("span");
    text.textContent = question;
    const ok = document.createElement("button");
    ok.type = "button";
    ok.className = danger ? "masu-confirm-ok masu-danger" : "masu-confirm-ok";
    ok.textContent = answer;
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "masu-confirm-cancel";
    cancel.textContent = this.message("cancel", {});
    const close = () => {
      el.remove();
      if (this.confirmEl === el) this.confirmEl = null;
      this.gridEl.focus({ preventScroll: true });
    };
    ok.addEventListener("click", () => {
      close();
      then();
    });
    cancel.addEventListener("click", close);
    el.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close();
      }
    });
    el.append(text, ok, cancel);
    this.uiEl.appendChild(el);
    this.confirmEl = el;
    ok.focus();
  }

  /** The row that adds one: "+ New row", across the grid. */
  private fillAddRow(rowEl: RowElement, index: number): void {
    rowEl.masuRow = undefined;
    rowEl.dataset.index = String(index);
    rowEl.classList.remove("masu-loading", "masu-group-row", "masu-draft", "masu-changed");
    rowEl.classList.add("masu-add-row");
    rowEl.classList.toggle("masu-row-even", index % 2 === 1);
    rowEl.setAttribute("aria-busy", "false");
    for (const name of ["aria-level", "aria-posinset", "aria-setsize", "aria-expanded"]) rowEl.removeAttribute(name);
    Array.from(rowEl.children).forEach((child, col) => {
      const cell = child as HTMLElement;
      if (col >= this.columns.length) {
        (cell.firstElementChild as HTMLElement | null)?.toggleAttribute("hidden", true);
        return;
      }
      cell.id = `${this.id}-r${index}-c${col}`;
      cell.textContent = col === 0 ? `+ ${this.message("new_row", {})}` : "";
      cell.classList.remove("masu-invalid", "masu-saving", "masu-editable", "masu-locked", "masu-null");
      cell.removeAttribute("aria-readonly");
      cell.removeAttribute("aria-invalid");
      cell.removeAttribute("title");
    });
  }

  // The other people who have the grid open (its Issho room): a line in
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
    for (const [id, mark] of this.peerMarks) {
      if (this.people.some((person) => person.id === id && person.cell)) continue;
      mark.remove();
      this.peerMarks.delete(id);
    }
    if (this.people.length === 0) return;

    const rowsById = new Map<string, number>();
    for (const [index, rowEl] of this.rows) {
      const data = rowEl.masuRow;
      if (data) rowsById.set(JSON.stringify(data[0]), index);
    }

    // Their selected ranges: a wash in their color on the cells of their
    // rows, wherever this person's order puts them.
    // A range selected from a cell (an agent's drag) sweeps over its rows,
    // from the first; a drawing during the sweep goes on with it.
    const now = performance.now();
    for (const person of this.people) {
      if (person.range && this.peerHadRange.get(person.id) === false) this.peerSweeps.set(person.id, now);
      this.peerHadRange.set(person.id, !!person.range);
      if (!person.range) continue;
      const cols = person.range.keys.map((key) => this.columns.findIndex((column) => column.key === key)).filter((col) => col >= 0);
      if (cols.length === 0) continue;
      const first = Math.min(...cols);
      const last = Math.max(...cols);
      const left = this.colLeft(first);
      const width = this.colLeft(last) + this.widths[last] - left;
      const began = this.peerSweeps.get(person.id);
      const elapsed = began === undefined ? Infinity : now - began;
      if (elapsed > 2_000) this.peerSweeps.delete(person.id);
      const rows = person.range.rows.length;
      for (const [line, id] of person.range.rows.entries()) {
        const index = rowsById.get(JSON.stringify(id));
        if (index === undefined) continue;
        const el = document.createElement("div");
        el.className = "masu-peer-range";
        if (elapsed <= 2_000 && !reducedMotion()) {
          el.dataset.sweep = "";
          el.style.setProperty("--masu-sweep-line", `${line / rows}`);
          el.style.setProperty("--masu-sweep-lines", `${rows}`);
          el.style.setProperty("--masu-sweep-elapsed", `${Math.round(elapsed)}ms`);
        }
        el.style.setProperty("--masu-peer-color", person.color);
        el.style.transform = `translateY(${this.rowY(index)}px)`;
        el.style.insetInlineStart = `${left}px`;
        el.style.width = `${width}px`;
        el.style.height = `${this.config.rowHeight}px`;
        el.setAttribute("aria-hidden", "true");
        this.body.appendChild(el);
        this.peerEls.push(el);
      }
    }

    const drawn = new Set<string>();
    for (const person of this.people) {
      if (!person.cell) continue;
      const index = rowsById.get(JSON.stringify(person.cell[0]));
      const col = this.columns.findIndex((column) => column.key === person.cell![1]);
      if (index === undefined || col < 0) continue;
      drawn.add(person.id);

      // The same mark as before, so that it glides there: longer the farther it goes.
      const known = this.peerMarks.get(person.id);
      const el = known ?? document.createElement("div");
      const y = this.rowY(index);
      const x = this.colLeft(col);
      if (known) {
        const far = Math.hypot(y - (Number(known.dataset.y) || 0), x - (Number(known.dataset.x) || 0));
        el.style.setProperty("--masu-peer-travel", `${Math.round(Math.min(400, Math.max(80, far * 0.8)))}ms`);
      }
      el.dataset.x = String(x);
      el.dataset.y = String(y);
      el.className = `masu-peer${person.editing ? " masu-peer-editing" : ""}${index === 0 ? " masu-peer-top" : ""}`;
      el.style.setProperty("--masu-peer-color", person.color);
      el.style.transform = `translateY(${y}px)`;
      el.style.insetInlineStart = `${x}px`;
      if (this.columns[col].pinned) el.classList.add("masu-peer-pinned");
      el.style.width = `${this.widths[col]}px`;
      el.style.height = `${this.config.rowHeight}px`;
      el.dataset.person = person.id;
      el.setAttribute("aria-hidden", "true");

      const label = (el.querySelector(":scope > .masu-peer-label") as HTMLElement | null) ?? document.createElement("span");
      label.className = "masu-peer-label";
      const custom = options.peerLabel?.(person);
      if (custom instanceof HTMLElement) label.replaceChildren(custom);
      else label.textContent = custom ?? (person.editing ? this.message("peer_typing", { label: person.name ?? "" }) : (person.name ?? ""));
      if (!label.parentNode) el.appendChild(label);

      if (el.parentNode !== this.body) this.body.appendChild(el);
      this.peerMarks.set(person.id, el);
    }
    for (const [id, mark] of this.peerMarks) {
      if (drawn.has(id)) continue;
      mark.remove();
      this.peerMarks.delete(id);
    }
  }

  /**
   * Where a place of the grid is in the viewport, for Issho's pointers: a
   * cell (`cell`: a row's id and a column's key), or a range, while its rows
   * are on this person's screen.
   */
  private locate(at: unknown): DOMRect | null {
    const place = at as { cell?: [unknown, string]; range?: { rows: unknown[]; keys: string[] } } | null;
    const cells: [unknown, string][] = place?.cell ? [place.cell] : place?.range ? place.range.rows.flatMap((id) => place.range!.keys.map((key) => [id, key] as [unknown, string])) : [];
    const body = this.body.getBoundingClientRect();
    let box: { left: number; top: number; right: number; bottom: number } | null = null;
    for (const [id, key] of cells) {
      let index: number | undefined;
      for (const [i, rowEl] of this.rows) if (rowEl.masuRow && JSON.stringify(rowEl.masuRow[0]) === JSON.stringify(id)) index = i;
      const col = this.columns.findIndex((column) => column.key === key);
      if (index === undefined || col < 0) continue;
      const left = body.left + this.colLeft(col);
      const top = body.top + this.rowY(index);
      const cell = { left, top, right: left + this.widths[col], bottom: top + this.config.rowHeight };
      box = box ? { left: Math.min(box.left, cell.left), top: Math.min(box.top, cell.top), right: Math.max(box.right, cell.right), bottom: Math.max(box.bottom, cell.bottom) } : cell;
    }
    return box ? new DOMRect(box.left, box.top, box.right - box.left, box.bottom - box.top) : null;
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
      const data = this.dataAt(index);
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
      scrollTop: this.contentTop(),
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
      this.scrollToContent(own.scrollTop);
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
      this.scrollToContent(this.rowTop(index));
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
      const data = this.active.row >= 0 ? this.dataAt(this.active.row) : undefined;
      // A new row is this person's own until it saves.
      const cell = data && !isDraft(data) ? [data[0], this.columns[this.active.col].key] : null;
      const range = this.rangeForOthers();
      // The first row on the screen, for those who follow this person.
      const first = this.cache.get(this.firstWholeRow());
      const top = first ? first[0] : null;
      const editing = this.editor !== null || this.formEditor !== null;
      const cursor = JSON.stringify([cell, range, editing, top]);
      if (cursor === this.sentCursor) return;
      this.sentCursor = cursor;
      this.transport.push("masu:cursor", { cell, range, editing, top });
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

  private copyText(first: number, last: number, selection: Rect, headers?: boolean): string {
    const lines: string[][] = [];
    if (headers ?? (selection.top === 0 && last === this.total - 1 && this.total > 1)) {
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
      const viewTop = this.contentTop();
      const viewBottom = viewTop + this.gridEl.clientHeight - headHeight;
      if (top < viewTop) this.scrollToContent(top);
      else if (bottom > viewBottom) this.scrollToContent(bottom - (this.gridEl.clientHeight - headHeight));
    }
    this.scrollToColumn(cell.col);
  }

  // Words for a screen reader.

  private message(name: string, values: MessageValues): string {
    const messages = this.messages();
    const template = name === "rows" && values.count === 1 ? messages.row : messages[name] ?? name;
    return this.fill(template, { count: 0, ...values });
  }

  /** A message's `{count}`, `{label}`, `{done}` and `{total}`, the numbers in the grid's locale. */
  private fill(template: string, values: MessageValues): string {
    const number = (n: number | undefined) => (n === undefined ? "" : new Intl.NumberFormat(this.config.locale ?? undefined).format(n));
    return template
      .replace("{count}", number(values.count))
      .replace("{label}", values.label ?? "")
      .replace("{done}", number(values.done))
      .replace("{total}", number(values.total));
  }

  private announceCount(): void {
    this.announce(this.message(this.exact ? "rows" : "rows_more", { count: this.total }));
  }

  private announceCopy(count: number): void {
    this.announce(this.message(count === 1 ? "copied_one" : "copied", { count }));
  }

  private announce(text: string): void {
    if (this.statusEl) this.statusEl.textContent = text;
  }
}

/**
 * The rows the browser keeps, in blocks of the server's size (a page's, in
 * a grid of pages): about six thousand rows, however large a block.
 */
function cacheFor(config: Config): BlockCache {
  const size = Math.max(1, config.blockSize ?? 100);
  return new BlockCache(size, Math.max(3, Math.ceil(6000 / size)));
}

/** A new row's id, until it saves: a string of its own. */
const DRAFT = "\u0000masu-draft:";

/** A new row, not saved yet. */
function isDraft(row: Row): boolean {
  return typeof row[0] === "string" && row[0].startsWith(DRAFT);
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

/** The types whose values have an order: a cell's menu filters by its value as a bound. */
const ORDERED: ColumnType[] = ["integer", "number", "decimal", "date", "datetime", "time"];

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
  op_in_many: "has any of",
  op_all_of: "has all of",
  op_none_of: "has none of",
  op_is_nil_many: "has none",
  op_not_nil_many: "has some",
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
  select_row: "Select the row",
  select_all: "Select every row",
  chosen: "{count} selected",
  chosen_all: "All {count} selected",
  clear_selection: "Clear",
  rows_more: "{count}+ rows",
  chosen_all_more: "All {count}+ selected",
  new_row: "New row",
  draft_discarded: "New row discarded",
  row_added: "Row added",
  row_added_hidden: "Row added; the filters leave it out",
  rows_added: "{count} rows added",
  paste_add: "Add {count} new rows for the rest of the paste?",
  add_rows: "Add rows",
  delete: "Delete",
  delete_one: "Delete this row?",
  delete_rows: "Delete {count} rows?",
  deleted_one: "Row deleted",
  deleted: "{count} rows deleted",
  restored: "{count} rows brought back",
  restored_one: "Row brought back",
  invalid_integer: "Not a whole number",
  invalid_number: "Not a number",
  invalid_date: "Not a date",
  invalid_time: "Not a time",
  invalid_datetime: "Not a date and time",
  invalid_value: "Not one of the values",
  not_saved: "Not saved.",
  cancel: "Cancel",
  export_menu: "Export",
  export_csv: "CSV",
  export_xlsx: "Excel (XLSX)",
  export_started: "The export is downloading",
  export_failed: "The export failed",
  detail_hidden: "Details hidden",
  view_reset: "The grid's own view",
  view_name: "Name this view",
  view_share: "Share with everyone",
  view_save: "Save view",
  view_saved: "View saved",
  view_shared: "Shared",
  view_delete: "Delete {label}",
  view_dropped: "Part of this view no longer applies: {label}",
  column_menu: "{label} menu",
  cell_menu: "{label}: actions",
  row_actions: "Row actions",
  history: "History",
  row_history: "Row history",
  history_of: "{label}: history",
  history_empty: "No changes yet",
  history_was: "was {label}",
  history_created: "Row added",
  history_deleted: "Row deleted",
  history_someone: "Someone",
  history_restore: "Restore {label}",
  history_restore_batch: "Undo all {count}",
  history_restored: "{count} restored",
  history_origin_paste: "pasted",
  history_origin_fill: "filled",
  history_origin_clear: "cleared",
  history_origin_undo: "undone",
  history_origin_redo: "redone",
  history_origin_restore: "restored",
  action_done: "{label}: done",
  action_running: "{label}: running…",
  action_progress: "{label}: {done} of {total}",
  saving_later: "Saving…",
  deleting_later: "Deleting…",
  copy: "Copy",
  copy_with_headers: "Copy with headers",
  filter_value: "Filter by {label}",
  exclude_value: "Exclude {label}",
  filter_empty: "Filter by empty",
  filter_not_empty: "Filter by not empty",
  filter_none: "Filter by none",
  filter_some: "Filter by some",
  filter_gt: "Greater than {label}",
  filter_lt: "Less than {label}",
  filter_gte: "At least {label}",
  filter_lte: "At most {label}",
  filter_gt_time: "After {label}",
  filter_lt_time: "Before {label}",
  filter_gte_time: "On or after {label}",
  filter_lte_time: "On or before {label}",
  filter_contains: "Contains {label}",
  sort_asc: "Sort ascending",
  sort_desc: "Sort descending",
  action_failed: "This action no longer applies",
};

// Three columns, and a stack of sheets, drawn for Masu.
const COLUMNS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><rect x="2" y="2.5" width="12" height="11" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 2.5v11M10 2.5v11" stroke="currentColor" stroke-width="1.4"/></svg>';
const VIEWS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 5.5 8 2.5l5.5 3L8 8.5z M2.5 8.5 8 11.5l5.5-3 M2.5 11 8 14l5.5-3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>';

// A tray with an arrow down, drawn for Masu.
const EXPORT_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M8 2.5v7M5 6.5l3 3 3-3M2.5 10.5v2a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// Three dots, drawn for Masu: a header's menu without a filter.
const MORE_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><circle cx="3.5" cy="8" r="1.25" fill="currentColor"/><circle cx="8" cy="8" r="1.25" fill="currentColor"/><circle cx="12.5" cy="8" r="1.25" fill="currentColor"/></svg>';

// A funnel, drawn for Masu.
const FILTER_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 3h11l-4.25 5v4.25l-2.5 1.25V8z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>';

interface Editor {
  input: HTMLInputElement;
  /** What the editor is drawn in: its input, or the box of an editor of the app's. */
  el: HTMLElement;
  /** An editor of the app's (`configure({editors})`). */
  own: CellEditor | null;
  row: number;
  col: number;
  id: unknown;
  original: CellValue;
  done: boolean;
  /** An enum's list of values, and those it shows, and the one picked. */
  list: HTMLElement | null;
  options: string[];
  shown: string[];
  highlight: number;
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
  /** What a form posts is params: text, and maps and lists of it. */
  value: string | boolean | null | FormValue;
  /** An edit of a form of the app's: what it posted when it opened, and the version of the value it opened with. */
  form?: { before: FormValue | string | boolean | null; version: number | null };
}

type FormValue = string | null | FormValue[] | { [key: string]: FormValue };

/** A cell edited with a form of the app's, in a popover the server renders. */
interface FormEditor {
  row: number;
  col: number;
  id: unknown;
  key: string;
  /** The version of the value it opened with; null until the server says. */
  version: number | null;
  /** What its form posted when it opened. */
  initial: FormValue | undefined;
  wired: boolean;
  done: boolean;
}

const MAX_EDITS = 5_000;
/** The most rows added or deleted at once (Masu.Edit). */
const MAX_NEW_ROWS = 1_000;

/** A new row: its values by column key, as they go to the server. */
interface Draft {
  id: string;
  values: Map<string, string | boolean | null>;
  row: Row;
  saving: boolean;
}

/** A step to undo or redo: edits of cells, a delete, or a delete undone. */
type Step = { kind: "edits"; edits: Edit[] } | { kind: "delete"; undo: string } | { kind: "restore"; ids: unknown[] };

/** A write or an action that goes on later, until its reply (Masu.reply/2). */
type Later =
  | { kind: "edits"; edits: Edit[]; mode: "edit" | "undo" | "redo" }
  | { kind: "delete"; count: number }
  | { kind: "action"; label: string };

/** An entry of the history of a cell or a row (Masu.History). */
interface HistoryEntry {
  id: string | null;
  key: string | null;
  op: "update" | "create" | "delete";
  before: unknown;
  after: unknown;
  user: string | null;
  origin: string;
  batch: string | null;
  batch_size: number;
  at: string;
}

/** The origins of an entry that its line says (a paste, a restore...). */
const HISTORY_ORIGINS = ["paste", "fill", "clear", "undo", "redo", "restore"];

interface MessageValues {
  count?: number;
  label?: string;
  done?: number;
  total?: number;
}

const FOCUSABLE = 'input:not([type="hidden"]), select, textarea, button, [contenteditable="true"], [tabindex]:not([tabindex="-1"])';

const MOVES = { down: { row: 1, col: 0 }, up: { row: -1, col: 0 }, right: { row: 0, col: 1 }, left: { row: 0, col: -1 } };

/**
 * What a form editor posts for the cell, `cell[value]`: text, or the
 * params under it (`cell[value][from]`, `cell[value][]`), as the server
 * reads a form's params; null when it posts nothing.
 */
export function formValue(form: HTMLFormElement): FormValue {
  let value: FormValue = null;
  for (const [name, entry] of new FormData(form)) {
    if (typeof entry !== "string" || !name.startsWith("cell[value]")) continue;
    const path = [...name.slice("cell[value]".length).matchAll(/\[([^\]]*)\]/g)].map((m) => m[1]);
    value = setPath(value, path, entry);
  }
  return value;
}

function setPath(into: FormValue, path: string[], entry: string): FormValue {
  if (path.length === 0) return entry;
  const [key, ...rest] = path;
  if (key === "") {
    const list = Array.isArray(into) ? into : [];
    return [...list, setPath(null, rest, entry)];
  }
  const map = into !== null && typeof into === "object" && !Array.isArray(into) ? into : {};
  return { ...map, [key]: setPath(map[key] ?? null, rest, entry) };
}

function cellKey(id: unknown, key: string): string {
  return `${JSON.stringify(id)}\u0000${key}`;
}

/** The value of a cell: an editable column of HEEx sends [html, value]. */
function rawValue(value: unknown): CellValue {
  return Array.isArray(value) ? (value[1] as CellValue) : (value as CellValue);
}

/** A value short enough for a menu's item. */
function clip(text: string): string {
  return text.length > 40 ? `${text.slice(0, 39)}…` : text;
}

function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);
}

/** The grid's config, and its words, which come apart so that they are sent once, not with each change of the config. */
function readConfig(el: HTMLElement): Config {
  const config = JSON.parse(el.dataset.masu ?? "{}") as Config;
  return { ...config, messages: JSON.parse(el.dataset.masuMessages ?? "{}") as Record<string, string> };
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

function reducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}
