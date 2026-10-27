// The pointer: a press on a cell selects (a drag a range, unless the grid
// selects none), on a header sorts
// or moves its column, on its edge resizes it; a double click edits or fits.

import { contains } from "../geometry";
import type { Grid } from "../grid";

export class Pointer {
  constructor(private readonly grid: Grid) {}

  onMouseDown(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    // A right click: the cell under it is the active one, unless it is in
    // the range selected, which its menu is for.
    if (event.button === 2) {
      const cell = this.grid.cellAt(target);
      if (!cell) return;
      this.grid.gridEl.focus({ preventScroll: true });
      const range = this.grid.highlight();
      if (!range || !contains(range, cell.row, cell.col)) {
        this.grid.active = cell;
        this.grid.anchor = null;
        this.grid.render();
      }
      return;
    }
    // A box (the click selects); the focus stays on the grid.
    if (target.closest(".masu-select, .masu-select-all")) {
      event.preventDefault();
      this.grid.gridEl.focus({ preventScroll: true });
      return;
    }
    // The arrow of a tree's row, and of a detail.
    const arrow = target.closest<HTMLElement>(".masu-twisty, .masu-detail-toggle");
    if (arrow) {
      const cell = this.grid.cellAt(arrow);
      if (cell) {
        event.preventDefault();
        this.grid.gridEl.focus({ preventScroll: true });
        this.grid.active = cell;
        this.grid.anchor = null;
        this.grid.render();
        if (arrow.classList.contains("masu-detail-toggle")) this.grid.details.toggleDetail(cell.row);
        else if (arrow.dataset.state !== "leaf") this.grid.toggleNode(cell.row, arrow.dataset.state === "closed");
        return;
      }
    }
    if (target.closest("a, button, input, select, textarea, label, [contenteditable]")) return;

    const resizer = target.closest<HTMLElement>(".masu-resizer");
    if (resizer) {
      event.preventDefault();
      this.grid.layout.startResize(event, Number(resizer.parentElement!.dataset.col));
      return;
    }

    const header = target.closest<HTMLElement>(".masu-hcell");
    if (header) {
      // A click sorts (on the release); a drag moves the column.
      event.preventDefault();
      this.grid.gridEl.focus({ preventScroll: true });
      const col = Number(header.dataset.col);
      this.grid.active = { row: -1, col };
      this.grid.anchor = null;
      this.grid.layout.headerPress = { col, x: event.clientX, shift: event.shiftKey, moved: false, target: null };
      this.grid.render();
      return;
    }

    const cell = this.grid.cellAt(target);
    if (!cell) return;
    event.preventDefault();
    this.grid.gridEl.focus({ preventScroll: true });
    // Ctrl (⌘) and a click selects the row, or takes it out.
    if (this.grid.config.selection && (event.ctrlKey || event.metaKey)) {
      this.grid.active = cell;
      this.grid.anchor = null;
      this.grid.rowSelection.onBox(cell.row, false);
      this.grid.render();
      return;
    }
    if (event.shiftKey) {
      if (!this.grid.anchor) this.grid.anchor = this.grid.active.row >= 0 ? { ...this.grid.active } : cell;
    } else {
      this.grid.anchor = cell;
    }
    this.grid.active = cell;
    // A drag selects a range; with no ranges, the cell pressed stays active.
    this.grid.dragging = this.grid.config.rangeSelect !== false;
    this.grid.render();
  }

  onMouseMove(event: MouseEvent): void {
    if (this.grid.layout.headerPress) {
      this.grid.layout.dragHeader(event);
      return;
    }
    if (!this.grid.dragging) return;
    const element = document.elementFromPoint(event.clientX, event.clientY) as HTMLElement | null;
    const cell = element && this.grid.gridEl.contains(element) ? this.grid.cellAt(element) : null;
    if (cell && (cell.row !== this.grid.active.row || cell.col !== this.grid.active.col)) {
      this.grid.active = cell;
      this.grid.render();
    }
  }

  onDoubleClick(event: MouseEvent): void {
    const resizer = (event.target as HTMLElement).closest<HTMLElement>(".masu-resizer");
    if (resizer) {
      this.grid.layout.autosize(Number(resizer.parentElement!.dataset.col));
      return;
    }
    const cell = this.grid.cellAt(event.target as HTMLElement);
    if (cell) this.grid.editing.startEdit(cell);
  }
}
