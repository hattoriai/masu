// The history of a cell or a row (Masu.History): its entries, from the
// server, and restoring one.

import { drop, floats, follow, lift, place as placeAt } from "../float";
import { HISTORY_ORIGINS, type HistoryEntry } from "../records";
import { cellKey, isDraft, isGroup } from "../rows";
import type { Cell } from "../geometry";
import type { CellValue } from "../types";
import type { Grid } from "../grid";

export class History {
  /** The history of a cell or a row (Masu.History), in a popover. */
  private historyEl: { el: HTMLElement; cleanup: () => void } | null = null;

  constructor(private readonly grid: Grid) {}

  /**
   * The history of a cell (or of its row): its values, newest first, who
   * set each and when, and Restore; Undo all for a batch of several cells
   * (someone's paste). In a popover under the cell, as a dialog.
   */
  openHistory(cell: Cell, ofCell: boolean): void {
    const data = this.grid.dataAt(cell.row);
    const column = this.grid.columns[cell.col];
    if (!data || !column || isGroup(data) || isDraft(data)) return;
    this.closeHistory(false);
    this.grid.actions.closeCellMenu(false);

    const el = document.createElement("div");
    el.className = "masu-menu masu-panel masu-history";
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-label", ofCell ? this.grid.message("history_of", { label: column.label }) : this.grid.message("row_history", {}));
    el.tabIndex = -1;
    const list = document.createElement("ol");
    list.className = "masu-history-list";
    list.setAttribute("aria-busy", "true");
    el.appendChild(list);
    this.grid.uiEl.appendChild(el);

    const place = () => {
      const box = (this.grid.actions.cellElement(cell) ?? this.grid.gridEl).getBoundingClientRect();
      if (floats(el)) {
        lift(el);
        placeAt(el, { left: box.left, below: box.bottom + 4, above: box.top - 4 });
      } else {
        const root = this.grid.el.getBoundingClientRect();
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
    this.grid.transport.push("masu:history", payload, (reply) => {
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
      empty.textContent = this.grid.message("history_empty", {});
      list.replaceChildren(empty);
      return;
    }
    const batches = new Set<string>();
    list.replaceChildren(
      ...entries.map((entry) => {
        const item = document.createElement("li");
        item.className = "masu-history-entry";
        const col = this.grid.columns.findIndex((column) => column.key === entry.key);
        const format = (value: unknown) =>
          col >= 0 ? this.grid.formatters[col](value as CellValue) || this.grid.message("empty_value", {}) : String(value ?? "");

        const what = document.createElement("div");
        what.className = "masu-history-what";
        if (entry.op === "create") what.textContent = this.grid.message("history_created", {});
        else if (entry.op === "delete") what.textContent = this.grid.message("history_deleted", {});
        else {
          const label = !ofCell && col >= 0 ? `${this.grid.columns[col].label}: ` : "";
          what.textContent = `${label}${format(entry.after)}`;
          const was = document.createElement("span");
          was.className = "masu-history-was";
          was.textContent = this.grid.message("history_was", { label: format(entry.before) });
          what.append(" ", was);
        }

        const who = document.createElement("div");
        who.className = "masu-history-who";
        const origin = HISTORY_ORIGINS.includes(entry.origin) ? ` · ${this.grid.message(`history_origin_${entry.origin}`, {})}` : "";
        const time = document.createElement("time");
        time.dateTime = entry.at;
        time.title = new Date(entry.at).toLocaleString(this.grid.config.locale ?? undefined);
        time.textContent = this.ago(entry.at);
        who.append(`${entry.user ?? this.grid.message("history_someone", {})} · `, time, origin);
        item.append(what, who);

        const actions = document.createElement("div");
        actions.className = "masu-history-actions";
        if (entry.op === "update" && col >= 0) {
          const restore = document.createElement("button");
          restore.type = "button";
          restore.className = "masu-history-restore";
          restore.textContent = this.grid.message("history_restore", { label: format(entry.before) });
          restore.addEventListener("click", () => this.restoreHistory({ entry: entry.id }));
          actions.appendChild(restore);
        }
        if (entry.batch && entry.batch_size > 1 && !batches.has(entry.batch)) {
          batches.add(entry.batch);
          const all = document.createElement("button");
          all.type = "button";
          all.className = "masu-history-restore-batch";
          all.textContent = this.grid.message("history_restore_batch", { count: entry.batch_size });
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
    const format = new Intl.RelativeTimeFormat(this.grid.config.locale ?? undefined, { numeric: "auto" });
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
    this.grid.transport.push("masu:history_restore", payload, (reply) => {
      const errors = (reply.errors as [unknown, string, string][]) ?? [];
      for (const [id, key, message] of errors) this.grid.editing.errors.set(cellKey(id, key), message);
      if (errors.length > 0) {
        const [, key, message] = errors[0];
        const column = this.grid.columns.find((c) => c.key === key);
        this.grid.announce(`${column?.label ?? key}: ${message}`);
      } else {
        this.grid.announce(this.grid.message("history_restored", { count: (reply.restored as number) ?? 0 }));
      }
      this.grid.refreshRows();
    });
  }

  private closeHistory(focus: boolean): void {
    if (!this.historyEl) return;
    const { el, cleanup } = this.historyEl;
    this.historyEl = null;
    cleanup();
    drop(el);
    el.remove();
    if (focus) this.grid.gridEl.focus({ preventScroll: true });
  }
}
