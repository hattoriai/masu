// The columns' layout: resizing (and fitting a column to its content),
// moving by a drag or the keyboard, and what goes to the server of it.

import { textWidth } from "../dom";
import { moveKey } from "../layout";
import { OVERSCAN } from "../limits";
import type { BlockReply } from "../types";
import type { Grid } from "../grid";

/** The widest a column grows to fit its content. */
const MAX_AUTO_WIDTH = 640;

export class ColumnLayout {
  /** A press on a header: a click sorts, a drag moves the column. */
  headerPress: { col: number; x: number; shift: boolean; moved: boolean; target: number | null } | null = null;
  private dropEl: HTMLElement | null = null;
  resizing = false;

  constructor(private readonly grid: Grid) {}

  startResize(event: MouseEvent, col: number): void {
    const startX = event.clientX;
    const startWidth = this.grid.widths[col];
    const sign = getComputedStyle(this.grid.gridEl).direction === "rtl" ? -1 : 1;
    this.grid.el.classList.add("masu-resizing");

    const onMove = (moveEvent: MouseEvent) => {
      this.setWidth(col, startWidth + sign * (moveEvent.clientX - startX));
    };
    this.resizing = true;
    const onUp = () => {
      this.resizing = false;
      this.grid.el.classList.remove("masu-resizing");
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      this.reportWidth(col);
    };
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  /** Gives a column a width: the person's, so a column that grew is that wide, and grows no more. */
  private setWidth(col: number, width: number): void {
    const column = this.grid.columns[col];
    this.grid.sizes[col] = Math.max(column.minWidth, Math.round(width));
    column.grow = 0;
    this.grid.applyWidths();
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
    measure(this.grid.headerRow.children[col]);
    for (const rowEl of this.grid.rows.values()) measure(rowEl.children[col]);
    this.setWidth(col, Math.min(Math.ceil(widest) + 4, MAX_AUTO_WIDTH));
    this.reportWidth(col);
  }

  /** Tells the server of a change of layout, with where the screen starts. */
  sendLayout(changes: { order?: string[]; hidden?: string[]; pinned?: Record<string, string>; widths?: Record<string, number> }): void {
    const from = Math.max(0, this.grid.indexAtTop() - OVERSCAN);
    this.grid.transport.push("masu:layout", { ...changes, from }, (reply) => {
      const answer = reply as unknown as BlockReply | null;
      if (answer?.rows) this.grid.takeBlock(answer);
    });
  }

  private reportWidth(col: number): void {
    const column = this.grid.columns[col];
    if (column) this.sendLayout({ widths: { [column.key]: this.grid.sizes[col] } });
  }

  /** Moves a column one place, among the columns of its pin. */
  moveColumn(col: number, step: -1 | 1): void {
    const column = this.grid.columns[col];
    const other = this.grid.columns[col + step];
    if (!column || !other || (column.pinned ?? null) !== (other.pinned ?? null)) return;
    const order = this.grid.config.catalog.map((c) => c.key);
    const moved = step < 0 ? moveKey(order, column.key, other.key) : moveKey(order, other.key, column.key);
    this.grid.active = { row: -1, col: col + step };
    this.sendLayout({ order: moved });
    this.grid.announce(this.grid.message("moved", { label: column.label }));
  }

  dragHeader(event: MouseEvent): void {
    const press = this.headerPress!;
    if (!press.moved && Math.abs(event.clientX - press.x) < 5) return;
    press.moved = true;
    this.grid.el.classList.add("masu-moving");

    // The place among the columns of its pin: before the first whose middle is past the pointer.
    const pin = this.grid.columns[press.col].pinned ?? null;
    const cells = Array.from(this.grid.headerRow.children) as HTMLElement[];
    const zone = this.grid.columns.map((c, col) => ({ c, col })).filter(({ c }) => (c.pinned ?? null) === pin);
    const rtl = getComputedStyle(this.grid.gridEl).direction === "rtl";
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
    if (!this.dropEl.isConnected) this.grid.head.appendChild(this.dropEl);
    const edge = target < this.grid.columns.length ? this.grid.colLeft(target) : this.grid.colLeft(target - 1) + this.grid.widths[target - 1];
    this.dropEl.style.insetInlineStart = `${edge - 1}px`;
    for (const cell of cells) cell.classList.toggle("masu-dragged", Number(cell.dataset.col) === press.col);
  }

  releaseHeader(): void {
    const press = this.headerPress;
    if (!press) return;
    this.headerPress = null;
    this.dropEl?.remove();
    this.grid.el.classList.remove("masu-moving");
    for (const cell of this.grid.headerRow.children) cell.classList.remove("masu-dragged");

    if (!press.moved) {
      this.grid.sortBy(press.col, press.shift);
      return;
    }
    const target = press.target;
    if (target === null || target === press.col || target === press.col + 1) return;
    const column = this.grid.columns[press.col];
    const order = this.grid.config.catalog.map((c) => c.key);
    let moved: string[];
    if (target < this.grid.columns.length && (this.grid.columns[target].pinned ?? null) === (column.pinned ?? null)) {
      moved = moveKey(order, column.key, this.grid.columns[target].key);
    } else {
      // After the last column of its pin.
      const last = this.grid.columns[target - 1].key;
      moved = moveKey(moveKey(order, column.key, last), last, column.key);
    }
    this.grid.active = { row: -1, col: target > press.col ? target - 1 : target };
    this.sendLayout({ order: moved });
    this.grid.announce(this.grid.message("moved", { label: column.label }));
  }
}
