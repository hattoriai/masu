// New rows (`create`): a row that adds one after the rows of the query, its
// cells edited as any other's, saved when the person leaves it; and rows
// pasted below the last.

import { FLASH } from "../limits";
import { sendValue, shownValue } from "../parse";
import { MAX_NEW_ROWS, type Draft, type RowElement } from "../records";
import { cellKey, DRAFT } from "../rows";
import type { Rect } from "../geometry";
import type { Row } from "../types";
import type { Grid } from "../grid";

export class NewRows {
  /**
   * New rows not saved yet (`create`), after the rows of the query, then
   * the row that adds one: each saves when the person leaves it.
   */
  drafts: Draft[] = [];
  private draftCount = 0;
  /** On its way to the last page, to add a row there. */
  private toLastPage = false;
  /** The draft the active cell was on, saved when it leaves it. */
  private activeDraft: string | null = null;

  constructor(private readonly grid: Grid) {}

  /** Takes drafts out, keeping the active cell on what it was on. */
  private dropDrafts(ids: Set<string>): void {
    const draft = this.grid.draftAt(this.grid.active.row);
    const adding = this.grid.active.row >= 0 && this.grid.active.row === this.grid.addIndex();
    for (const d of this.drafts) {
      if (!ids.has(d.id)) continue;
      for (const column of this.grid.columns) this.grid.editing.errors.delete(cellKey(d.id, column.key));
    }
    this.drafts = this.drafts.filter((d) => !ids.has(d.id));
    if (draft && !ids.has(draft.id)) this.grid.active = { row: this.grid.span() + this.drafts.indexOf(draft), col: this.grid.active.col };
    else if (draft || adding) this.grid.active = { row: Math.max(0, Math.min(this.grid.addIndex(), this.grid.rowCount() - 1)), col: this.grid.active.col };
    this.activeDraft = this.grid.draftAt(this.grid.active.row)?.id ?? null;
    this.grid.anchor = null;
    this.grid.clearRows();
  }

  draftRow(draft: Draft): Row {
    return [draft.id, ...this.grid.columns.map((column) => shownValue(column.type, draft.values.get(column.key) ?? null))] as Row;
  }

  setDraftValue(draft: Draft, key: string, value: string | boolean | null): void {
    if (value === null || value === "") draft.values.delete(key);
    else draft.values.set(key, value);
    this.grid.editing.errors.delete(cellKey(draft.id, key));
    draft.row = this.draftRow(draft);
  }

  private newDraft(): Draft {
    const draft: Draft = { id: `${DRAFT}${++this.draftCount}`, values: new Map(), row: [null] as unknown as Row, saving: false };
    draft.row = this.draftRow(draft);
    return draft;
  }

  /** A new row, under the others; the one the person was on saves. */
  addDraft(): void {
    if (!this.grid.config.creates) return;
    // In a grid of pages, new rows are on the last page: it goes there first.
    if (this.grid.paged() && this.grid.end() < this.grid.rowCount()) {
      if (this.toLastPage) return;
      this.toLastPage = true;
      this.grid.askCount(() => {
        const last = Math.max(0, Math.ceil(this.grid.total / this.grid.config.pageSize) - 1);
        this.grid.transport.push("masu:page", { page: last }, () => {
          // The page comes with the server's render; the new row after it.
          setTimeout(() => {
            this.toLastPage = false;
            if (this.grid.end() === this.grid.rowCount()) this.addDraft();
          }, 0);
        });
      });
      return;
    }
    const current = this.grid.draftAt(this.grid.active.row);
    if (current) this.saveDrafts([current.id]);
    const draft = this.newDraft();
    this.drafts.push(draft);
    const editable = this.grid.columns.findIndex((column) => column.creatable);
    const col = this.grid.columns[this.grid.active.col]?.creatable ? this.grid.active.col : Math.max(0, editable);
    this.grid.active = { row: this.grid.span() + this.drafts.length - 1, col };
    this.activeDraft = draft.id;
    this.grid.anchor = null;
    this.grid.gridEl.focus({ preventScroll: true });
    this.grid.ensureVisible(this.grid.active);
    this.grid.render();
    this.grid.announce(this.grid.message("new_row", {}));
  }

  discardDraft(id: string): void {
    this.dropDrafts(new Set([id]));
    this.grid.render();
    this.grid.announce(this.grid.message("draft_discarded", {}));
  }

  /** The active cell left a draft: it saves. */
  leaveDraft(): void {
    const now = this.grid.draftAt(this.grid.active.row)?.id ?? null;
    const left = this.activeDraft;
    this.activeDraft = now;
    if (left && left !== now && !this.grid.editing.editor) setTimeout(() => this.saveDrafts([left]), 0);
  }

  /**
   * Saves drafts (`masu:create`): a saved one leaves the drafts (its row
   * comes in the query's rows, with a flash); a refused one stays, with
   * its errors on its cells. An empty draft just goes.
   */
  saveDrafts(ids: string[], showRefused = false): void {
    const wanted = new Set(ids);
    const drafts = this.drafts.filter((d) => wanted.has(d.id) && !d.saving);
    const empty = drafts.filter((d) => d.values.size === 0);
    if (empty.length > 0) {
      this.dropDrafts(new Set(empty.map((d) => d.id)));
      this.grid.render();
    }
    const saving = drafts.filter((d) => d.values.size > 0);
    if (saving.length === 0) return;
    for (const draft of saving) {
      draft.saving = true;
      for (const key of draft.values.keys()) this.grid.editing.saving.add(cellKey(draft.id, key));
    }
    this.grid.refreshRows();

    const rows = saving.map((draft) => Object.fromEntries(draft.values));
    this.grid.transport.push("masu:create", { rows, origin: showRefused ? "paste" : "draft" }, (reply) => {
      for (const draft of saving) {
        draft.saving = false;
        for (const key of draft.values.keys()) this.grid.editing.saving.delete(cellKey(draft.id, key));
      }
      if (typeof reply.error === "string") {
        this.grid.announce(reply.error);
        this.grid.refreshRows();
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
            const column = this.grid.columns.find((c) => c.key === key) ?? this.grid.columns[0];
            this.grid.editing.errors.set(cellKey(draft.id, column.key), message);
            firstError ??= `${column.label}: ${message}`;
          }
          draft.row = this.draftRow(draft);
        } else {
          saved.add(draft.id);
          this.grid.flash.set(String(result.id), { until: now + FLASH, color: undefined });
        }
      });
      if (saved.size > 0) this.dropDrafts(saved);
      if (typeof reply.total === "number") this.grid.setTotal(reply.total);
      // New rows of a paste that the server refused: the first is shown.
      const refused = saving.find((draft) => !saved.has(draft.id));
      if (showRefused && refused) {
        const col = this.grid.columns.findIndex((column) => this.grid.editing.errors.has(cellKey(refused.id, column.key)));
        this.grid.active = { row: this.grid.span() + this.drafts.indexOf(refused), col: Math.max(0, col) };
        this.activeDraft = refused.id;
        this.grid.anchor = null;
        this.grid.ensureVisible(this.grid.active);
      }
      this.grid.refreshRows();

      if (firstError) this.grid.announce(firstError);
      else if (saved.size > 1) this.grid.announce(this.grid.message("rows_added", { count: saved.size }));
      else if (saved.size === 1) this.grid.announce(this.grid.message(reply.index === null ? "row_added_hidden" : "row_added", {}));
    });
  }

  /** Lines of a paste on the new rows: their values, and more new rows. */
  pasteIntoDrafts(matrix: string[][], selection: Rect): void {
    const first = selection.top - this.grid.span();
    const lines = matrix.slice(0, MAX_NEW_ROWS);
    while (this.drafts.length < first + lines.length) this.drafts.push(this.newDraft());
    this.fillDrafts(this.drafts.slice(first, first + lines.length), lines, selection.left);
    this.grid.anchor = { row: selection.top, col: selection.left };
    this.grid.active = { row: selection.top + lines.length - 1, col: Math.min(selection.left + Math.max(...lines.map((l) => l.length)) - 1, this.grid.columns.length - 1) };
    this.activeDraft = this.grid.draftAt(this.grid.active.row)?.id ?? null;
    this.grid.clearRows();
    this.grid.render();
  }

  /** The lines of a paste past the last row, as new rows, saved at once. */
  addPastedRows(lines: string[][], left: number): void {
    const drafts = lines.map(() => this.newDraft());
    this.drafts.push(...drafts);
    this.fillDrafts(drafts, lines, left);
    this.grid.render();
    this.saveDrafts(
      drafts.map((d) => d.id),
      true,
    );
  }

  private fillDrafts(drafts: Draft[], lines: string[][], left: number): void {
    const locale = this.grid.config.locale ?? undefined;
    drafts.forEach((draft, r) => {
      lines[r].forEach((text, c) => {
        const column = this.grid.columns[left + c];
        if (column?.creatable) this.setDraftValue(draft, column.key, sendValue(column.type, text, locale));
      });
    });
  }

  discardDrafts(ids: Set<string>): void {
    this.dropDrafts(ids);
    this.grid.render();
    this.grid.announce(this.grid.message("draft_discarded", {}));
  }

  /** The row that adds one: "+ New row", across the grid. */
  fillAddRow(rowEl: RowElement, index: number): void {
    rowEl.masuRow = undefined;
    rowEl.dataset.index = String(index);
    rowEl.classList.remove("masu-loading", "masu-group-row", "masu-draft", "masu-changed");
    rowEl.classList.add("masu-add-row");
    rowEl.classList.toggle("masu-row-even", index % 2 === 1);
    rowEl.setAttribute("aria-busy", "false");
    for (const name of ["aria-level", "aria-posinset", "aria-setsize", "aria-expanded"]) rowEl.removeAttribute(name);
    Array.from(rowEl.children).forEach((child, col) => {
      const cell = child as HTMLElement;
      if (col >= this.grid.columns.length) {
        (cell.firstElementChild as HTMLElement | null)?.toggleAttribute("hidden", true);
        return;
      }
      cell.id = `${this.grid.id}-r${index}-c${col}`;
      cell.textContent = col === 0 ? `+ ${this.grid.message("new_row", {})}` : "";
      cell.classList.remove("masu-invalid", "masu-saving", "masu-editable", "masu-locked", "masu-null");
      cell.removeAttribute("aria-readonly");
      cell.removeAttribute("aria-invalid");
      cell.removeAttribute("title");
    });
  }
}
