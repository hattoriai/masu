// Selection (`selectable`): the server holds it; the browser shows it, the
// boxes of the rows and of the header, and the bar of how many.

import { MAX_EDITS } from "../records";
import { isGroup } from "../rows";
import type { Grid } from "../grid";

export class RowSelection {
  /** The rows selected (`selectable`), as JSON ids; every row of the query less `except` when `all`. */
  chosen = { all: false, ids: new Set<string>(), except: new Set<string>(), count: 0 };
  /** The row of the last box clicked: the start of a Shift click's range. */
  private lastChosen: number | null = null;
  selectionBar: HTMLElement | null = null;

  constructor(private readonly grid: Grid) {}

  /** Reads the selection of the config; whether it changed. */
  readSelection(): boolean {
    const selection = this.grid.config.selection;
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

  isChosen(id: unknown): boolean {
    const key = JSON.stringify(id);
    return this.chosen.all ? !this.chosen.except.has(key) : this.chosen.ids.has(key);
  }

  /** Selects or takes out rows by their indexes (those the browser has, or loads). */
  private choose(first: number, last: number, on: boolean): void {
    const top = Math.min(first, last);
    const bottom = Math.min(Math.max(first, last), top + MAX_EDITS - 1);
    this.grid.load(top, bottom, () => {
      const ids: unknown[] = [];
      for (let index = top; index <= bottom; index++) {
        const row = this.grid.cache.get(index);
        if (row && !isGroup(row)) ids.push(row[0]);
      }
      if (ids.length === 0) return;
      for (const id of ids) {
        const key = JSON.stringify(id);
        if (this.chosen.all) (on ? this.chosen.except.delete(key) : this.chosen.except.add(key));
        else on ? this.chosen.ids.add(key) : this.chosen.ids.delete(key);
      }
      this.grid.refreshRows();
      // The header's box: every row, some, or none.
      this.grid.renderHeader();
      this.grid.transport.push("masu:select", { ids, on }, (reply) => {
        if (typeof reply?.count === "number") this.grid.announce(this.grid.message("chosen", { count: reply.count as number }));
      });
    });
  }

  /** The box of a row was clicked (Shift: the range from the last one). */
  onBox(index: number, shift: boolean): void {
    const row = this.grid.dataAt(index);
    if (!row) return;
    const on = !this.isChosen(row[0]);
    if (shift && this.lastChosen !== null) this.choose(this.lastChosen, index, on);
    else this.choose(index, index, on);
    this.lastChosen = index;
  }

  /** Every row of the query, or none. */
  chooseAll(on: boolean): void {
    this.chosen = { all: on, ids: new Set(), except: new Set(), count: on ? this.grid.total : 0 };
    this.grid.refreshRows();
    this.grid.renderHeader();
    this.grid.transport.push("masu:select", { all: on }, (reply) => {
      if (typeof reply?.count === "number") this.grid.announce(this.grid.message("chosen", { count: reply.count as number }));
    });
  }

  /** "1,234 selected", with Clear, above the grid while rows are selected. */
  private renderSelectionBar(): void {
    if (!this.grid.config.selection || this.chosen.count === 0) {
      this.selectionBar?.remove();
      this.selectionBar = null;
      return;
    }
    if (!this.selectionBar) {
      this.selectionBar = document.createElement("div");
      this.selectionBar.className = "masu-selection-bar";
      this.grid.uiEl.appendChild(this.selectionBar);
    }
    const text = document.createElement("span");
    const all = this.chosen.all && this.chosen.except.size === 0;
    text.textContent = this.grid.message(all ? (this.grid.config.selection.exact === false ? "chosen_all_more" : "chosen_all") : "chosen", {
      count: this.chosen.count,
    });
    const clear = document.createElement("button");
    clear.type = "button";
    clear.className = "masu-selection-clear";
    clear.textContent = this.grid.message("clear_selection", {});
    clear.addEventListener("click", () => this.chooseAll(false));
    this.selectionBar.replaceChildren(text);
    for (const action of this.grid.config.actions ?? []) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `masu-selection-action${action.danger ? " masu-danger" : ""}`;
      button.textContent = action.label;
      button.addEventListener("click", () => this.grid.actions.runSelectionAction(action));
      this.selectionBar.appendChild(button);
    }
    this.selectionBar.appendChild(clear);
    if (this.grid.config.deletes) {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "masu-selection-delete masu-danger";
      remove.textContent = this.grid.message("delete", {});
      remove.addEventListener("click", () => this.grid.deleting.confirmDelete(this.chosen.count, { selection: true }));
      this.selectionBar.insertBefore(remove, clear);
    }
  }
}
