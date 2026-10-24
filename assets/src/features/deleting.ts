// Deleting rows (`delete`, `deletable`): Ctrl+Delete on a range, or the
// selection's Delete, asked first; and the rows restored by an undo.

import { FLASH } from "../limits";
import { MAX_NEW_ROWS } from "../records";
import { isGroup } from "../rows";
import type { Grid } from "../grid";

export class Deleting {
  /** A question above the grid: delete rows, add the rest of a paste, an action's `confirm`. */
  private confirmEl: HTMLElement | null = null;

  constructor(private readonly grid: Grid) {}

  deleteRows(): void {
    // The rows selected with their boxes, when there are.
    if (this.grid.config.selection && this.grid.rowSelection.chosen.count > 0) {
      this.confirmDelete(this.grid.rowSelection.chosen.count, { selection: true });
      return;
    }
    const range = this.grid.selection();
    if (!range) return;
    // New rows in the range just go.
    const drafts = new Set<string>();
    for (let index = Math.max(range.top, this.grid.span()); index <= range.bottom; index++) {
      const draft = this.grid.draftAt(index);
      if (draft) drafts.add(draft.id);
    }
    if (drafts.size > 0) this.grid.newRows.discardDrafts(drafts);
    if (!this.grid.config.deletes || range.top >= this.grid.span()) return;
    const bottom = Math.min(range.bottom, this.grid.span() - 1, range.top + MAX_NEW_ROWS - 1);
    this.grid.load(range.top, bottom, () => {
      const ids: unknown[] = [];
      for (let index = range.top; index <= bottom; index++) {
        const row = this.grid.cache.get(index);
        if (row && !isGroup(row)) ids.push(row[0]);
      }
      if (ids.length > 0) this.confirmDelete(ids.length, { ids });
    });
  }

  confirmDelete(count: number, payload: { ids: unknown[] } | { selection: true }): void {
    const question = count === 1 ? this.grid.message("delete_one", {}) : this.grid.message("delete_rows", { count });
    this.confirm(question, this.grid.message("delete", {}), () => this.pushDelete(payload, false), true);
  }

  /** Deletes rows; the step goes on the undo stack (or, for a redo, back on it). */
  pushDelete(payload: { ids: unknown[] } | { selection: true }, redo: boolean): void {
    const origin = redo ? "redo" : "selection" in payload ? "selection" : "rows";
    this.grid.transport.push("masu:delete", { ...payload, origin }, (reply) => {
      if (typeof reply.error === "string") {
        this.grid.announce(reply.error);
        return;
      }
      // Rows deleted later (Masu.Write.async/1): the reply says how it went.
      const later = (reply.saving as unknown[]) ?? [];
      if (typeof reply.async === "string" && later.length > 0) {
        this.grid.later.set(reply.async, { kind: "delete", count: later.length });
        if (((reply.deleted as number) ?? 0) === 0) {
          this.grid.announce(this.grid.message("deleting_later", {}));
          return;
        }
      }
      const deleted = (reply.deleted as number) ?? 0;
      const errors = (reply.errors as [unknown, string][]) ?? [];
      if (typeof reply.total === "number") this.grid.setTotal(reply.total);
      this.grid.anchor = null;
      if (deleted > 0 && typeof reply.undo === "string") {
        this.grid.editing.undoStack.push({ kind: "delete", undo: reply.undo });
        if (!redo) this.grid.editing.redoStack = [];
      }
      const said = deleted === 1 ? this.grid.message("deleted_one", {}) : this.grid.message("deleted", { count: deleted });
      this.grid.announce(errors.length > 0 ? `${deleted > 0 ? `${said} ` : ""}${errors[0][1]}` : said);
      this.grid.render();
    });
  }

  /** Brings back the rows of a delete (Ctrl+Z); a redo deletes them again. */
  restoreRows(undo: string): void {
    this.grid.transport.push("masu:restore", { undo }, (reply) => {
      if (typeof reply.error === "string") {
        this.grid.announce(reply.error);
        return;
      }
      const ids = (reply.ids as unknown[]) ?? [];
      if (typeof reply.total === "number") this.grid.setTotal(reply.total);
      const now = performance.now();
      for (const id of ids) this.grid.flash.set(String(id), { until: now + FLASH, color: undefined });
      if (ids.length > 0) this.grid.editing.redoStack.push({ kind: "restore", ids });
      this.grid.announce(ids.length === 1 ? this.grid.message("restored_one", {}) : this.grid.message("restored", { count: ids.length }));
      this.grid.render();
    });
  }

  /**
   * A question above the grid, with its answer and Cancel; the answer has
   * the focus, Escape cancels, and the focus goes back to the grid.
   */
  confirm(question: string, answer: string, then: () => void, danger = false): void {
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
    cancel.textContent = this.grid.message("cancel", {});
    const close = () => {
      el.remove();
      if (this.confirmEl === el) this.confirmEl = null;
      this.grid.gridEl.focus({ preventScroll: true });
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
    this.grid.uiEl.appendChild(el);
    this.confirmEl = el;
    ok.focus();
  }
}
