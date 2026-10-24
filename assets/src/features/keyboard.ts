// The keyboard: the arrows and their moves, the header row, Enter to sort,
// the menus' keys, a row's keys (its detail, a tree's node, opening it), and
// selecting.

import { move } from "../geometry";
import { isDraft, isGroup } from "../rows";
import type { Grid } from "../grid";

export class Keyboard {
  constructor(private readonly grid: Grid) {}

  onKeyDown(event: KeyboardEvent): void {
    const mod = event.ctrlKey || event.metaKey;
    if (this.grid.editing.editor) return;
    // A form editor opens: the keys before it takes the focus are not the grid's.
    if (this.grid.editing.formEditor) {
      event.preventDefault();
      if (event.key === "Escape") this.grid.editing.closeFormEditor(true);
      return;
    }

    // The history of the active cell (Ctrl+Alt+H), with a history.
    if (this.grid.config.history && mod && event.altKey && event.code === "KeyH" && this.grid.active.row >= 0) {
      event.preventDefault();
      this.grid.history.openHistory(this.grid.active, true);
      return;
    }
    // The menu of the active cell, or of the header.
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
      this.grid.menuKeyAt = performance.now();
      if (this.grid.active.row === -1) {
        if (!this.grid.filters.hasHeaderMenu(this.grid.active.col)) return;
        event.preventDefault();
        this.grid.filters.openMenu(this.grid.active.col);
      } else if (this.grid.actions.openCellMenu(this.grid.active, null)) {
        event.preventDefault();
      }
      return;
    }
    if (this.onRowKey(event, mod)) return;
    if (this.grid.editing.onEditKey(event, mod)) return;
    if (this.grid.activation.onKey(event)) return;

    if (mod && event.key.toLowerCase() === "a") {
      event.preventDefault();
      if (this.grid.total === 0) return;
      this.grid.anchor = { row: 0, col: 0 };
      this.grid.active = { row: this.grid.total - 1, col: this.grid.columns.length - 1 };
      this.grid.render();
      this.grid.announce(this.grid.message("selected", { count: this.grid.total }));
      return;
    }

    if (event.key === "Escape" && this.grid.anchor) {
      // Taken: a grid around this.grid one (in a detail) leaves the focus here.
      event.preventDefault();
      this.grid.anchor = null;
      this.grid.render();
      return;
    }

    if (event.altKey && event.shiftKey && this.grid.active.row === -1 && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      const rtl = getComputedStyle(this.grid.gridEl).direction === "rtl";
      this.grid.layout.moveColumn(this.grid.active.col, (event.key === "ArrowRight") !== rtl ? 1 : -1);
      return;
    }

    if (event.altKey && event.key === "ArrowDown" && this.grid.active.row === -1) {
      event.preventDefault();
      this.grid.filters.openMenu(this.grid.active.col);
      return;
    }

    if ((event.key === "Enter" || event.key === " ") && this.grid.active.row === -1) {
      event.preventDefault();
      this.grid.sortBy(this.grid.active.col, event.shiftKey);
      return;
    }

    const target = move(this.grid.active, event.key, mod, {
      rows: this.grid.end(),
      cols: this.grid.columns.length,
      page: this.grid.pageRows(),
      rtl: getComputedStyle(this.grid.gridEl).direction === "rtl",
    });
    if (!target) return;
    event.preventDefault();
    // A page's rows: above its first, the header.
    if (target.row >= 0 && target.row < this.grid.base()) target.row = this.grid.active.row === this.grid.base() ? -1 : this.grid.base();
    // Ctrl+End where the count is not known: it is asked for first.
    if (!this.grid.exact && mod && (event.key === "End" || event.key === "ArrowDown") && !this.grid.countAsked) {
      this.grid.askCount(() => {
        this.grid.active = { row: this.grid.end() - 1, col: target.col };
        this.grid.anchor = null;
        this.grid.ensureVisible(this.grid.active);
        this.grid.render();
      });
      return;
    }

    if (event.shiftKey && target.row >= 0) {
      if (!this.grid.anchor) this.grid.anchor = this.grid.active.row >= 0 ? { ...this.grid.active } : { row: 0, col: this.grid.active.col };
    } else {
      this.grid.anchor = null;
    }
    this.grid.active = target;
    this.grid.ensureVisible(target);
    this.grid.render();
  }

  /**
   * The keys of a row: in a tree, → opens the row of the active cell of the
   * first column, ← closes it (or goes to its parent), * opens every row
   * beside it; Alt+→ and Alt+← open and close a row's detail, Alt+↓ goes
   * into it.
   */
  private onRowKey(event: KeyboardEvent, mod: boolean): boolean {
    const { row, col } = this.grid.active;
    if (row < 0 || mod) return false;
    const data = this.grid.dataAt(row);
    if (!data || isDraft(data)) return false;

    // Space on the first column selects the row, or takes it out.
    if (this.grid.config.selection && event.key === " " && col === 0 && !event.altKey && !isGroup(data)) {
      event.preventDefault();
      this.grid.rowSelection.onBox(row, event.shiftKey);
      return true;
    }

    if (event.altKey && this.grid.config.detail) {
      if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
        event.preventDefault();
        this.grid.details.toggleDetail(row, event.key === "ArrowRight");
        return true;
      }
      if (event.key === "ArrowDown" && this.grid.details.focusDetail(row)) {
        event.preventDefault();
        return true;
      }
    }

    const node = this.grid.nodeOf(data);
    if (!node || col !== 0 || event.altKey) return false;
    // * takes Shift on most keyboards; the arrows with Shift select.
    if (event.key === "*") {
      event.preventDefault();
      this.grid.toggleNode(row, true, true);
      return true;
    }
    if (event.shiftKey) return false;
    if (event.key === "ArrowRight" && node.children && !node.expanded) {
      event.preventDefault();
      this.grid.toggleNode(row, true);
      return true;
    }
    if (event.key === "ArrowLeft") {
      if (node.children && node.expanded) {
        event.preventDefault();
        this.grid.toggleNode(row, false);
        return true;
      }
      if (node.level > 0) {
        // To the parent: the row above with a smaller level.
        for (let index = row - 1; index >= 0; index--) {
          const above = this.grid.dataAt(index);
          const aboveNode = above ? this.grid.nodeOf(above) : null;
          if (aboveNode && aboveNode.level < node.level) {
            event.preventDefault();
            this.grid.active = { row: index, col };
            this.grid.anchor = null;
            this.grid.ensureVisible(this.grid.active);
            this.grid.render();
            return true;
          }
        }
      }
    }
    return false;
  }
}
