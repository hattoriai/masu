// The other people who have the grid open (its Issho room): a line in their
// color on the cell they are on, where the row is on this person's screen
// (their order and filters are their own), with their name; their pointers;
// and following one of them, which shows their view.

import { reducedMotion } from "../dom";
import { describe } from "../filters";
import { activeIn, followIn, followingIn } from "../following";
import { options } from "../options";
import { isDraft } from "../rows";
import { sameView } from "../view";
import type { OwnView } from "../records";
import type { CellValue, Person, QuerySpec } from "../types";
import type { Grid } from "../grid";

/** How long the cursor waits before it goes to the others. */
const CURSOR_DELAY = 150;

export class Peers {
  /** The other people who have the grid open, and their marks. */
  people: Person[] = [];
  private peerEls: HTMLElement[] = [];
  // Each person's mark on their cell, kept from one drawing to the next so
  // that it glides to their next cell; and when a range they selected from
  // a cell began to sweep over its rows.
  private peerMarks = new Map<string, HTMLElement>();
  /** The others' pointers over cells, when the grid draws them (no Issho pointers of its room on the page). */
  private peerPointers = new Map<string, HTMLElement>();
  /** This person's pointer over a cell, to share, and the last one shared. */
  private pointerAt: { cell: [unknown, string]; x: number; y: number } | null = null;
  private pointerTimer: number | null = null;
  private sentPointer = "null";
  /** The person this grid scrolled into view for, following them. */
  private shownFor: string | null = null;
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
  refusedView: string | null = null;
  private followEl: HTMLElement | null = null;
  cursorTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly grid: Grid) {}

  setPeople(people: Person[]): void {
    this.people = people;
    this.drawPeople();
    const room = this.followRoom();
    const wanted = room ? followingIn(room) : null;
    if (wanted && this.following !== wanted && people.some((person) => person.id === wanted)) this.startFollowing(wanted);
    else if (this.following) this.follow();
    else this.markFollowed();
  }

  drawPeople(): void {
    for (const el of this.peerEls) el.remove();
    this.peerEls = [];
    for (const [id, mark] of this.peerMarks) {
      if (this.people.some((person) => person.id === id && person.cell)) continue;
      mark.remove();
      this.peerMarks.delete(id);
    }
    if (this.people.length === 0) return;

    const rowsById = new Map<string, number>();
    for (const [index, rowEl] of this.grid.rows) {
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
      const cols = person.range.keys.map((key) => this.grid.columns.findIndex((column) => column.key === key)).filter((col) => col >= 0);
      if (cols.length === 0) continue;
      const first = Math.min(...cols);
      const last = Math.max(...cols);
      const left = this.grid.colLeft(first);
      const width = this.grid.colLeft(last) + this.grid.widths[last] - left;
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
        el.style.transform = `translateY(${this.grid.rowY(index)}px)`;
        el.style.insetInlineStart = `${left}px`;
        el.style.width = `${width}px`;
        el.style.height = `${this.grid.config.rowHeight}px`;
        el.setAttribute("aria-hidden", "true");
        this.grid.body.appendChild(el);
        this.peerEls.push(el);
      }
    }

    const drawn = new Set<string>();
    for (const person of this.people) {
      if (!person.cell) continue;
      const index = rowsById.get(JSON.stringify(person.cell[0]));
      const col = this.grid.columns.findIndex((column) => column.key === person.cell![1]);
      if (index === undefined || col < 0) continue;
      drawn.add(person.id);

      // The same mark as before, so that it glides there: longer the farther it goes.
      const known = this.peerMarks.get(person.id);
      const el = known ?? document.createElement("div");
      const y = this.grid.rowY(index);
      const x = this.grid.colLeft(col);
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
      if (this.grid.columns[col].pinned) el.classList.add("masu-peer-pinned");
      el.style.width = `${this.grid.widths[col]}px`;
      el.style.height = `${this.grid.config.rowHeight}px`;
      el.dataset.person = person.id;
      el.setAttribute("aria-hidden", "true");

      const label = (el.querySelector(":scope > .masu-peer-label") as HTMLElement | null) ?? document.createElement("span");
      label.className = "masu-peer-label";
      const custom = options.peerLabel?.(person);
      if (custom instanceof HTMLElement) label.replaceChildren(custom);
      else label.textContent = custom ?? (person.editing ? this.grid.message("peer_typing", { label: person.name ?? "" }) : (person.name ?? ""));
      if (!label.parentNode) el.appendChild(label);

      if (el.parentNode !== this.grid.body) this.grid.body.appendChild(el);
      this.peerMarks.set(person.id, el);
    }
    for (const [id, mark] of this.peerMarks) {
      if (drawn.has(id)) continue;
      mark.remove();
      this.peerMarks.delete(id);
    }
    this.drawPointers(rowsById);
  }

  // The others' pointers over its cells, which the grid draws when no
  // Issho pointers of its room are on the page: an arrow and their name,
  // at the same spot of the same cell for each person, whatever their
  // order, filters and scroll.
  private drawPointers(rowsById: Map<string, number>): void {
    const drawn = new Set<string>();
    if (!this.roomLayer()) {
      for (const person of this.people) {
        const at = person.pointer;
        if (!at) continue;
        const index = rowsById.get(JSON.stringify(at.cell[0]));
        const col = this.grid.columns.findIndex((column) => column.key === at.cell[1]);
        if (index === undefined || col < 0) continue;
        drawn.add(person.id);
        let el = this.peerPointers.get(person.id);
        if (!el) {
          el = document.createElement("div");
          el.className = "masu-pointer";
          el.setAttribute("aria-hidden", "true");
          el.innerHTML = '<svg viewBox="0 0 16 16" width="16" height="16"><path d="M1 1 L1 13 L4.5 9.5 L7 15 L9 14 L6.5 8.5 L11.5 8.5 Z"/></svg><span class="masu-pointer-name"></span>';
          this.peerPointers.set(person.id, el);
        }
        el.querySelector(".masu-pointer-name")!.textContent = person.name ?? "";
        el.style.setProperty("--masu-peer-color", person.color);
        const x = this.grid.colLeft(col) + at.x * this.grid.widths[col];
        const y = this.grid.rowY(index) + at.y * this.grid.config.rowHeight;
        el.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
        if (el.parentNode !== this.grid.body) this.grid.body.appendChild(el);
      }
    }
    for (const [id, el] of this.peerPointers) {
      if (drawn.has(id)) continue;
      el.remove();
      this.peerPointers.delete(id);
    }
  }

  /**
   * Where a place of the grid is in the viewport, for Issho's pointers: a
   * cell (`cell`: a row's id and a column's key), or a range, while its rows
   * are on this person's screen.
   */
  locate(at: unknown): DOMRect | null {
    const place = at as { cell?: [unknown, string]; range?: { rows: unknown[]; keys: string[] } } | null;
    const cells: [unknown, string][] = place?.cell ? [place.cell] : place?.range ? place.range.rows.flatMap((id) => place.range!.keys.map((key) => [id, key] as [unknown, string])) : [];
    const body = this.grid.body.getBoundingClientRect();
    let box: { left: number; top: number; right: number; bottom: number } | null = null;
    for (const [id, key] of cells) {
      let index: number | undefined;
      for (const [i, rowEl] of this.grid.rows) if (rowEl.masuRow && JSON.stringify(rowEl.masuRow[0]) === JSON.stringify(id)) index = i;
      const col = this.grid.columns.findIndex((column) => column.key === key);
      if (index === undefined || col < 0) continue;
      const left = body.left + this.grid.colLeft(col);
      const top = body.top + this.grid.rowY(index);
      const cell = { left, top, right: left + this.grid.widths[col], bottom: top + this.grid.config.rowHeight };
      box = box ? { left: Math.min(box.left, cell.left), top: Math.min(box.top, cell.top), right: Math.max(box.right, cell.right), bottom: Math.max(box.bottom, cell.bottom) } : cell;
    }
    return box ? new DOMRect(box.left, box.top, box.right - box.left, box.bottom - box.top) : null;
  }

  /**
   * The cell under a point of the viewport, as the others find it (its
   * row's id and its column's key), and where in it (x and y, fractions of
   * its box); null over no cell of this grid.
   */
  cellUnder(x: number, y: number): { cell: [unknown, string]; x: number; y: number } | null {
    const target = document.elementFromPoint(x, y) as HTMLElement | null;
    const cell = target && this.grid.gridEl.contains(target) ? this.grid.cellAt(target) : null;
    const data = cell ? this.grid.dataAt(cell.row) : null;
    const column = cell ? this.grid.columns[cell.col] : undefined;
    if (!cell || !data || !column) return null;
    const box = target!.closest<HTMLElement>(".masu-cell")!.getBoundingClientRect();
    const fraction = (value: number, from: number, size: number) => Math.round(Math.min(1, Math.max(0, size > 0 ? (value - from) / size : 0.5)) * 100) / 100;
    return { cell: [data[0], column.key], x: fraction(x, box.left, box.width), y: fraction(y, box.top, box.height) };
  }

  /**
   * The selected range as the others can draw it in their own order: the
   * ids of its rows that the browser has (at most 500) and its columns'
   * keys.
   */
  private rangeForOthers(): { rows: unknown[]; keys: string[] } | null {
    const range = this.grid.highlight();
    if (!range || (range.top === range.bottom && range.left === range.right)) return null;
    const rows: unknown[] = [];
    for (let index = range.top; index <= range.bottom && rows.length < 500; index++) {
      const data = this.grid.dataAt(index);
      if (data) rows.push(data[0]);
    }
    return { rows, keys: this.grid.columns.slice(range.left, range.right + 1).map((column) => column.key) };
  }

  /** The room the grid follows in: none for a grid that takes no part in following (`follow={false}`). */
  followRoom(): string | null {
    return this.grid.config.follow === false ? null : this.room();
  }

  /** The Issho room of the grid: the part of its document before the "/". */
  private room(): string | null {
    const doc = this.grid.el.dataset.isshoDoc;
    return doc ? doc.slice(0, doc.indexOf("/") > 0 ? doc.indexOf("/") : doc.length) : null;
  }

  /**
   * Follows a person, or stops following them, in the grid's room: following
   * is Issho's, so every block of the room follows them with the grid. Stop
   * brings this person's own view back.
   */
  toggleFollow(id: string): void {
    const room = this.followRoom();
    if (!room) return;
    if (this.following === id) {
      this.stopFollowing(true);
      followIn(room, null);
      return;
    }
    followIn(room, id);
  }

  /** The person went their own way in the grid: no one is followed in the room. */
  goOwnWay(): void {
    if (!this.following) return;
    this.stopFollowing(false);
    const room = this.followRoom();
    if (room) followIn(room, null);
  }

  /**
   * Shows the followed person's view (their order, filters and search, when
   * their grid shares them) and keeps their place in it on the screen; the
   * person's own view is kept aside, and comes back on Stop.
   */
  startFollowing(id: string): void {
    // Followed in the room, but not in this grid (in another block): it
    // follows them when they come.
    if (this.following === id || !this.people.some((person) => person.id === id)) return;
    this.ownView ??= {
      query: this.grid.query,
      scrollTop: this.grid.contentTop(),
      scrollLeft: this.grid.gridEl.scrollLeft,
      active: { ...this.grid.active },
      anchor: this.grid.anchor && { ...this.grid.anchor },
    };
    this.following = id;
    this.refusedView = null;
    // A grid in a page (a document) comes into view once for the person it
    // follows, when it is off the screen; the page then scrolls as this
    // person likes.
    if (this.shownFor !== id) {
      this.shownFor = id;
      const rect = this.grid.el.getBoundingClientRect();
      if (rect.bottom <= 0 || rect.top >= document.documentElement.clientHeight) this.grid.el.scrollIntoView({ block: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
    }
    this.follow();
  }

  /**
   * Stops following. Stop (`restore`) brings the person's own view back;
   * their own scrolling, clicking or typing keeps the view they see, with
   * "Back to your view" while it is not their own.
   */
  stopFollowing(restore: boolean): void {
    if (!this.following) return;
    const person = this.followed;
    this.following = null;
    delete this.grid.el.dataset.following;
    this.markFollowed();

    if (restore) this.backToOwnView();
    else if (this.ownView && person && !sameView(this.ownView.query, this.grid.query)) this.showBanner(person, "their_view");
    else {
      this.ownView = null;
      this.removeBanner();
    }
  }

  /** The person made a view of their own: nothing to go back to. */
  dropFollow(): void {
    const room = this.followRoom();
    if (this.following && room) followIn(room, null);
    this.following = null;
    this.ownView = null;
    delete this.grid.el.dataset.following;
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
      this.grid.scrollToContent(own.scrollTop);
      this.grid.gridEl.scrollLeft = own.scrollLeft;
      this.grid.active = { row: Math.min(own.active.row, this.grid.total - 1), col: own.active.col };
      this.grid.anchor = own.anchor;
      this.grid.render();
    };
    if (sameView(own.query, this.grid.query)) place();
    else this.grid.setQuery(own.query, "restore", place);
  }

  /** Shows the followed person's view, then their place in it. */
  private follow(): void {
    const person = this.people.find((p) => p.id === this.following);
    if (!person) {
      // They left the grid (they may be in another block of the room): the
      // grid keeps what it shows, and follows them again when they come back.
      this.stopFollowing(false);
      return;
    }
    this.followed = person;
    this.grid.el.dataset.following = person.id;
    this.grid.el.style.setProperty("--masu-follow-color", person.color);
    this.showBanner(person, "following");
    this.markFollowed();

    const view = person.view;
    if (view && !sameView(view, this.grid.query) && JSON.stringify(view) !== this.refusedView) {
      this.grid.setQuery(view, "follow", () => this.placeFollowed());
      this.announceView(person, view);
    } else if (!this.grid.querying) {
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
    const shared = person.view !== null && sameView(person.view, this.grid.query);
    const top = shared && person.top !== null && person.top !== undefined ? person.top : null;
    const target = top ?? person.cell?.[0];
    if (target === undefined || target === null) return;
    const col = person.cell ? Math.max(0, this.grid.columns.findIndex((column) => column.key === person.cell![1])) : -1;

    const place = (index: number | null) => {
      if (this.following !== person.id) return;
      if (index === null) {
        this.showBanner(person, "follow_hidden");
        return;
      }
      if (top === null) {
        this.grid.scrollToCell(index, Math.max(col, 0));
        return;
      }
      // Their screen's first row first, then their cell, if this screen
      // is smaller than theirs.
      this.grid.scrollToContent(this.grid.rowTop(index));
      this.grid.render();
      const cell = person.cell ? this.grid.indexOf(person.cell[0]) : undefined;
      if (cell !== undefined) this.grid.scrollToCell(cell, Math.max(col, 0));
    };

    const index = this.grid.indexOf(target);
    if (index !== undefined) {
      place(index);
      return;
    }
    const revision = this.grid.revision;
    this.grid.transport.push("masu:locate", { id: target }, (reply) => {
      if (reply.revision !== revision) return;
      place((reply.index as number | null | undefined) ?? null);
    });
  }

  /** Says whose view the grid now shows, with its filters, for a screen reader. */
  private announceView(person: Person, view: QuerySpec): void {
    const messages = this.grid.messages();
    const parts = view.filters.flatMap((filter) => {
      const col = this.grid.columns.findIndex((column) => column.key === filter.key);
      return col < 0 ? [] : [describe(filter, this.grid.columns[col], (value) => this.grid.formatters[col](value as CellValue), messages)];
    });
    if (view.search) parts.push(`"${view.search}"`);
    const text = this.grid.message("showing_view", { label: person.name ?? person.id });
    this.grid.announce(parts.length > 0 ? `${text}: ${parts.join("; ")}` : text);
  }

  /**
   * The banner above the grid: "Following Ada" with Stop, "Ada is on a row
   * your filters leave out", or, once the person took over, "Ada's view"
   * with "Back to your view".
   */
  private showBanner(person: Person, kind: "following" | "follow_hidden" | "their_view"): void {
    // "Following Ada" is the people list's to say: this grid's, when it lists its people.
    if (kind === "following" && !this.grid.el.querySelector(":scope > .masu-people")) {
      this.removeBanner();
      return;
    }
    if (!this.followEl) {
      this.followEl = document.createElement("div");
      // Issho's look of following (its classes and properties), the same on every block of the page.
      this.followEl.className = "masu-following issho-following";
      this.followEl.setAttribute("role", "status");
      this.grid.uiEl.appendChild(this.followEl);
    }
    const name = person.name ?? person.id;
    const words = this.grid.message(kind, { label: name });
    this.followEl.style.setProperty("--masu-follow-color", person.color);
    this.followEl.style.setProperty("--issho-color", person.color);
    // Drawn again only when it says something new: a button replaced
    // under the pointer loses its click.
    if (this.followEl.dataset.kind === kind && this.followEl.firstChild?.textContent === words) return;
    this.followEl.dataset.kind = kind;
    const text = document.createElement("span");
    text.textContent = words;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "masu-following-stop issho-following-stop";
    button.dataset.isshoFollowControl = "";
    if (kind === "their_view") {
      button.textContent = this.grid.message("back_to_view", {});
      button.addEventListener("click", () => this.backToOwnView());
    } else {
      button.textContent = this.grid.message("stop_following", {});
      button.addEventListener("click", () => {
        this.stopFollowing(true);
        const room = this.followRoom();
        if (room) followIn(room, null);
      });
    }
    this.followEl.replaceChildren(text, button);
  }

  private removeBanner(): void {
    this.followEl?.remove();
    this.followEl = null;
    this.grid.el.style.removeProperty("--masu-follow-color");
  }

  /** The avatar of the person followed is pressed. */
  markFollowed(): void {
    for (const el of this.grid.el.querySelectorAll<HTMLElement>(":scope > .masu-people .masu-person[data-person]")) {
      el.setAttribute("aria-pressed", el.dataset.person === this.following ? "true" : "false");
    }
  }

  /** Tells the others where this person is, when it changes, at most every 150 ms. */
  reportCursor(): void {
    if (!this.grid.config.presence || this.cursorTimer || !this.inUse()) return;
    this.cursorTimer = setTimeout(() => {
      this.cursorTimer = null;
      const data = this.grid.active.row >= 0 ? this.grid.dataAt(this.grid.active.row) : undefined;
      // A new row is this person's own until it saves.
      const cell = data && !isDraft(data) ? [data[0], this.grid.columns[this.grid.active.col].key] : null;
      const range = this.rangeForOthers();
      // The first row on the screen, for those who follow this person.
      const first = this.grid.cache.get(this.grid.firstWholeRow());
      const top = first ? first[0] : null;
      const editing = this.grid.editing.editor !== null || this.grid.editing.formEditor !== null;
      const cursor = JSON.stringify([cell, range, editing, top]);
      if (cursor === this.sentCursor) return;
      this.sentCursor = cursor;
      this.grid.transport.push("masu:cursor", { cell, range, editing, top });
    }, CURSOR_DELAY);
  }

  /** Whether this copy of the grid is the one the person uses (there is one, or this is it). */
  private inUse(): boolean {
    const doc = this.grid.el.dataset.isshoDoc;
    const active = doc ? activeIn.get(doc) : undefined;
    return !active || active === this.grid || !active.el.isConnected;
  }

  /** Whether Issho's pointers of the grid's room are on the page: they share and draw the pointers. */
  private roomLayer(): boolean {
    const room = this.room();
    return !!room && document.querySelector(`.issho-pointers[data-room="${CSS.escape(room)}"]`) !== null;
  }

  /** Shares this person's pointer over a cell (or none), at most every 60 ms. */
  sharePointer(at: { cell: [unknown, string]; x: number; y: number } | null): void {
    if (!this.grid.config.presence || this.roomLayer() || !this.inUse()) return;
    this.pointerAt = at;
    if (this.pointerTimer !== null) return;
    this.pointerTimer = window.setTimeout(() => {
      this.pointerTimer = null;
      const json = JSON.stringify(this.pointerAt);
      if (json === this.sentPointer) return;
      this.sentPointer = json;
      this.grid.transport.push("masu:pointer", { at: this.pointerAt });
    }, 60);
  }
}
