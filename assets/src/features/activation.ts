// Opening a row (`on_row_activate`): a click on a row, or Enter on its
// active cell, tells the server which row; the app opens it (a panel
// beside the grid, its page). Only a cell that does not edit opens its
// row: on a cell that edits, a click and Enter are the editor's.

import { isDraft, isGroup } from "../rows";
import type { Cell } from "../geometry";
import type { Grid } from "../grid";

/** What a click in a cell does of its own: it does not open the row. */
const OWN_CLICK = "a, button, input, select, textarea, label, summary, [contenteditable], [role='button'], .masu-select, .masu-twisty, .masu-detail-toggle";

export class RowActivation {
  /** The cell a press started on, with no editor open; a click opens its row only there. */
  private pressed: Cell | null = null;

  constructor(private readonly grid: Grid) {}

  /** A press: where it starts, unless it ends an editor or selects. */
  onMouseDown(event: MouseEvent): void {
    this.pressed = null;
    if (!this.grid.config.activates || event.button !== 0 || this.modified(event)) return;
    if (this.grid.editing.editor || this.grid.editing.formEditor) return;
    this.pressed = this.grid.cellAt(event.target as HTMLElement);
  }

  /** A click on the cell it was pressed on, with no range dragged: opens its row. */
  onClick(event: MouseEvent): void {
    const pressed = this.pressed;
    this.pressed = null;
    // The second click of a double click is not another.
    if (!pressed || event.detail > 1 || this.modified(event)) return;
    const target = event.target as HTMLElement;
    if (target.closest(OWN_CLICK)) return;
    const cell = this.grid.cellAt(target);
    if (!cell || cell.row !== pressed.row || cell.col !== pressed.col) return;
    const { active, anchor } = this.grid;
    if (active.row !== cell.row || active.col !== cell.col) return;
    if (anchor && (anchor.row !== cell.row || anchor.col !== cell.col)) return;
    this.activate(cell);
  }

  /** Enter on the active cell of a row, which does not edit: opens the row. */
  onKey(event: KeyboardEvent): boolean {
    if (!this.grid.config.activates || event.key !== "Enter" || this.modified(event)) return false;
    if (!this.activate(this.grid.active)) return false;
    event.preventDefault();
    return true;
  }

  private activate(cell: Cell): boolean {
    if (cell.row < 0) return false;
    const data = this.grid.dataAt(cell.row);
    if (!data || isDraft(data) || isGroup(data) || this.grid.edits(data, cell.col)) return false;
    this.grid.transport.push("masu:activate", { id: data[0] });
    return true;
  }

  private modified(event: MouseEvent | KeyboardEvent): boolean {
    return event.shiftKey || event.ctrlKey || event.metaKey || event.altKey;
  }
}
