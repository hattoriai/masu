// Editing. A cell of an editable column takes Enter, F2, a double click or
// typing; its editor, an enum's list of values, an editor of the app's or a
// form the server renders; the edits it sends, their replies, undo and redo,
// clearing, filling down and pasting.

import { escapeHTML, FOCUSABLE, setStyle } from "../dom";
import { drop, floats, follow, lift, place as placeAt } from "../float";
import { formValue } from "../forms";
import { options } from "../options";
import { fromTSV, inputText, invalid, matching, placePaste, sendValue, shownValue } from "../parse";
import { MAX_EDITS, MAX_NEW_ROWS, MOVES, type Edit, type Editor, type FormEditor, type Step } from "../records";
import { cellKey, isDraft, isGroup, rawValue } from "../rows";
import type { Cell, Rect } from "../geometry";
import type { CellEditorFactory, CellValue, ColumnConfig, Row } from "../types";
import type { Grid } from "../grid";

export class Editing {
  /** The cell being edited. */
  editor: Editor | null = null;
  /** The cell being edited with a form of the app's, which the server renders in a popover. */
  formEditor: FormEditor | null = null;
  /** Places the form editor's popover again as the page scrolls. */
  private formFollow: (() => void) | null = null;
  /** The errors of cells the server did not save, by cellKey(). */
  errors = new Map<string, string>();
  /** The cells being saved, by cellKey(). */
  saving = new Set<string>();
  undoStack: Step[] = [];
  redoStack: Step[] = [];
  /** Edits sent and not answered; an undo or a redo before their answer waits for it. */
  private inFlight = 0;
  private waiting: ("undo" | "redo")[] = [];

  constructor(private readonly grid: Grid) {}

  onEditKey(event: KeyboardEvent, mod: boolean): boolean {
    const { row, col } = this.grid.active;
    const column = this.grid.columns[col];
    const key = event.key;

    // A new row: Ctrl+Enter or Insert, or Enter on the row that adds one.
    if (this.grid.config.creates && ((mod && key === "Enter") || (key === "Insert" && !mod && !event.shiftKey))) {
      event.preventDefault();
      this.grid.newRows.addDraft();
      return true;
    }
    if (row >= 0 && row === this.grid.addIndex() && (key === "Enter" || key === " ")) {
      event.preventDefault();
      this.grid.newRows.addDraft();
      return true;
    }
    // Ctrl+Delete (⌘⌫): the rows of the range, or those selected.
    if (mod && (key === "Delete" || key === "Backspace")) {
      if (!this.grid.config.deletes && !this.grid.draftAt(row)) return false;
      event.preventDefault();
      this.grid.deleting.deleteRows();
      return true;
    }
    // Escape on a new row lets it go.
    if (key === "Escape" && !this.grid.anchor && this.grid.draftAt(row)) {
      event.preventDefault();
      this.grid.newRows.discardDraft(this.grid.draftAt(row)!.id);
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
    const data = this.grid.dataAt(row);
    if (!data || !this.grid.edits(data, col)) return false;

    if (column.type === "boolean" && (key === " " || key === "Enter")) {
      event.preventDefault();
      const current = this.valueAt(row, col);
      this.applyEdits([{ row, col, value: !(current === true) }]);
      return true;
    }
    if (key === "Enter" || key === "F2") {
      event.preventDefault();
      this.startEdit(this.grid.active);
      return true;
    }
    if (key === "Delete" || key === "Backspace") {
      event.preventDefault();
      this.clearCells();
      return true;
    }
    if (key.length === 1 && !mod && !event.altKey && column.type !== "boolean") {
      event.preventDefault();
      this.startEdit(this.grid.active, key);
      return true;
    }
    return false;
  }

  /** Opens the editor of a cell, with its value, or with `text` typed on it. */
  startEdit(cell: Cell, text?: string): void {
    const column = this.grid.columns[cell.col];
    const row = this.grid.dataAt(cell.row);
    if (!column || !row || cell.row < 0 || !this.grid.edits(row, cell.col)) return;
    // An editor of the app's (not for a new row, which has no id yet).
    const own = isDraft(row) ? null : column.editor;
    const factory = own?.kind === "js" ? options.editors?.[own.name] : undefined;
    if (own?.kind === "js" && !factory) console.warn(`Masu: no editor "${own.name}" given to configure({editors})`);
    if (column.type === "boolean" && !own) return;
    const editor = this.grid.peers.people.find((person) => person.editing && person.cell && cellKey(person.cell[0], person.cell[1]) === cellKey(row[0], column.key));
    if (editor) {
      this.grid.announce(this.grid.message("peer_editing", { label: editor.name ?? "" }));
      return;
    }

    this.grid.active = { ...cell };
    this.grid.anchor = null;
    this.grid.ensureVisible(cell);
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
    input.style.transform = `translateY(${this.grid.rowY(cell.row)}px)`;
    input.style.insetInlineStart = `${this.grid.colLeft(cell.col)}px`;
    input.style.width = `${this.grid.widths[cell.col]}px`;
    input.style.height = `${this.grid.config.rowHeight}px`;

    this.editor = { input, el: input, own: null, row: cell.row, col: cell.col, id: row[0], original: raw, done: false, list: null, options: [], shown: [], highlight: -1 };
    input.addEventListener("keydown", (event) => this.onEditorKey(event));
    input.addEventListener("blur", () => this.commitEdit(null, true));
    this.grid.body.appendChild(input);
    if (column.type === "enum") this.openChoices(this.editor, column, text !== undefined);
    input.focus();
    if (text === undefined && input.type === "text") input.setSelectionRange(input.value.length, input.value.length);
    this.grid.peers.reportCursor();
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
    box.style.transform = `translateY(${this.grid.rowY(cell.row)}px)`;
    box.style.insetInlineStart = `${this.grid.colLeft(cell.col)}px`;
    box.style.width = `${this.grid.widths[cell.col]}px`;
    box.style.minHeight = `${this.grid.config.rowHeight}px`;
    this.grid.body.appendChild(box);

    const input = document.createElement("input");
    const editor: Editor = { input, el: box, own: null, row: cell.row, col: cell.col, id: row[0], original: raw, done: false, list: null, options: [], shown: [], highlight: -1 };
    this.editor = editor;
    const values = Object.fromEntries(this.grid.columns.map((c, col) => [c.key, rawValue(row[col + 1])]));
    editor.own = factory({
      element: box,
      value: raw,
      text,
      id: row[0],
      row: values,
      column,
      options: editorOptions,
      label: column.label,
      locale: this.grid.config.locale ?? null,
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
    this.grid.peers.reportCursor();
  }

  /** Saves the value of an editor of the app's, checked by the column's type, and moves. */
  private commitOwn(value: CellValue, step: { row: number; col: number } | null, blur: boolean): void {
    const editor = this.editor;
    if (!editor || editor.done) return;
    const column = this.grid.columns[editor.col];
    const changed = JSON.stringify(value ?? null) !== JSON.stringify(editor.original ?? null);
    const problem = changed && typeof value !== "number" ? invalid(column.type, value as string | boolean | null, column.values) : null;
    if (problem && !blur) {
      this.grid.announce(`${column.label}: ${this.grid.message(problem, {})}`);
      return;
    }
    this.closeEditor();
    if (problem) {
      this.grid.announce(`${column.label}: ${this.grid.message(problem, {})} ${this.grid.message("not_saved", {})}`);
      return;
    }
    const sent = typeof value === "number" ? String(value) : (value as string | boolean | null);
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value: sent, before: editor.original }]);
    if (step) {
      this.grid.active = {
        row: Math.min(Math.max(editor.row + step.row, 0), this.grid.rowCount() - 1),
        col: Math.min(Math.max(editor.col + step.col, 0), this.grid.columns.length - 1),
      };
      this.grid.ensureVisible(this.grid.active);
      this.grid.render();
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
    this.grid.actions.closeActionPanel(false);
    const editor: FormEditor = { row: cell.row, col: cell.col, id: row[0], key: column.key, version: null, initial: undefined, wired: false, done: false };
    this.formEditor = editor;
    this.grid.render();
    this.grid.peers.reportCursor();
    this.grid.transport.push("masu:cell_editor", { id: row[0], key: column.key }, (reply) => {
      if (this.formEditor !== editor) return;
      if (typeof reply.version !== "number") {
        this.formEditor = null;
        this.grid.peers.reportCursor();
        this.grid.announce(this.grid.message("not_editable", { count: 1 }));
        return;
      }
      editor.version = reply.version;
      this.placeFormEditor();
    });
  }

  /** The popover of the form editor, as the server rendered it. */
  private formEditorEl(): HTMLElement | null {
    return this.grid.el.querySelector<HTMLElement>(":scope > .masu-panels > .masu-cell-editor");
  }

  /** Places the form editor's popover under its cell, and wires it the first time. */
  placeFormEditor(): void {
    const editor = this.formEditor;
    const popover = this.formEditorEl();
    if (!editor || !popover || popover.dataset.key !== editor.key) {
      this.formFollow?.();
      this.formFollow = null;
      return;
    }
    const target = this.grid.actions.cellElement({ row: editor.row, col: editor.col });
    const box = (target ?? this.grid.gridEl).getBoundingClientRect();
    if (floats(popover)) {
      lift(popover);
      placeAt(popover, { left: box.left, below: box.bottom + 4, above: box.top - 4 }, (name, value) => setStyle(popover, name, value));
      this.formFollow ??= follow(() => this.placeFormEditor());
    } else {
      const root = this.grid.el.getBoundingClientRect();
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
    const data = this.grid.dataAt(editor.row);
    const before = data && data[0] === editor.id ? rawValue(data[editor.col + 1]) : null;
    this.send([{ id: editor.id, key: editor.key, col: editor.col, row: editor.row, before, value, form: { before: editor.initial, version: editor.version } }], "edit", "edit");
  }

  closeFormEditor(focus: boolean): void {
    if (!this.formEditor) return;
    this.formEditor = null;
    this.formFollow?.();
    this.formFollow = null;
    const popover = this.formEditorEl();
    if (popover) {
      drop(popover);
      popover.hidden = true;
    }
    this.grid.transport.push("masu:cell_editor", { open: false });
    this.grid.peers.reportCursor();
    if (focus) this.grid.gridEl.focus({ preventScroll: true });
  }

  /**
   * An enum's editor: a list of its values under the cell (or above, at
   * the bottom of the grid), which narrows as the person types; ↑ and ↓
   * pick, Enter takes. The values are the column's own (`values`), or the
   * values its rows have (as its filter menu has them).
   */
  private openChoices(editor: Editor, column: ColumnConfig, typed: boolean): void {
    const list = document.createElement("ul");
    const listId = `${this.grid.id}-choices`;
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
    const top = this.grid.rowY(editor.row);
    const room = this.grid.gridEl.scrollTop + this.grid.gridEl.clientHeight - (top + this.grid.config.rowHeight + this.grid.head.offsetHeight);
    list.style.insetInlineStart = `${this.grid.colLeft(editor.col)}px`;
    list.style.minWidth = `${this.grid.widths[editor.col]}px`;
    if (room < 200 && top - this.grid.gridEl.scrollTop > room) {
      list.style.transform = `translateY(calc(${top}px - 100%))`;
    } else {
      list.style.transform = `translateY(${top + this.grid.config.rowHeight}px)`;
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
    this.grid.body.appendChild(list);

    const show = (values: CellValue[]) => {
      if (this.editor !== editor) return;
      editor.options = values.filter((value) => value !== null).map((value) => String(value));
      this.showChoices(editor, typed);
    };
    if (column.values && column.values.length > 0) show(column.values);
    else
      this.grid.transport.push("masu:values", { key: column.key }, (reply) => {
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
      item.id = `${this.grid.id}-choice-${index}`;
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
    const column = this.grid.columns[editor.col];
    const changed = editor.input.value !== inputText(column.type, editor.original);
    const value = sendValue(column.type, editor.input.value, this.grid.config.locale ?? undefined);
    // A value the server would refuse (text in a number): the editor stays,
    // and says so; leaving it lets the value go.
    const problem = changed ? invalid(column.type, value, column.values) : null;
    if (problem && !blur) {
      editor.input.setAttribute("aria-invalid", "true");
      editor.input.title = this.grid.message(problem, {});
      this.grid.announce(`${column.label}: ${this.grid.message(problem, {})}`);
      return;
    }
    editor.done = true;
    this.closeEditor();
    if (problem) {
      this.grid.announce(`${column.label}: ${this.grid.message(problem, {})} ${this.grid.message("not_saved", {})}`);
      return;
    }
    // The value the person saw is the one the editor opened with: a save
    // by someone else while they typed is a conflict, not their base.
    if (changed) this.applyEdits([{ row: editor.row, col: editor.col, value, before: editor.original }]);
    if (step) {
      this.grid.active = {
        row: Math.min(Math.max(editor.row + step.row, 0), this.grid.rowCount() - 1),
        col: Math.min(Math.max(editor.col + step.col, 0), this.grid.columns.length - 1),
      };
      this.grid.ensureVisible(this.grid.active);
      this.grid.render();
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
    this.grid.gridEl.focus({ preventScroll: true });
    this.grid.render();
    this.grid.peers.reportCursor();
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
      const column = this.grid.columns[col];
      const data = this.grid.dataAt(row);
      if (!column || !data || !this.grid.edits(data, col)) {
        skipped += 1;
        continue;
      }
      // A value the server would refuse stays out, with its error.
      const problem = invalid(column.type, value, column.values);
      if (problem) {
        this.errors.set(cellKey(data[0], column.key), this.grid.message(problem, {}));
        firstProblem ??= `${column.label}: ${this.grid.message(problem, {})}`;
        continue;
      }
      // A new row keeps its values until it saves.
      const draft = this.grid.draftAt(row);
      if (draft) {
        this.grid.newRows.setDraftValue(draft, column.key, value);
        drafted = true;
        continue;
      }
      const before = seen !== undefined ? seen : rawValue(data[col + 1]);
      edits.push({ id: data[0], key: column.key, col, row, before, value });
      this.setValue(row, col, column.html ? [escapeHTML(String(value ?? "")), shownValue(column.type, value)] : shownValue(column.type, value));
    }
    if (skipped > 0) this.grid.announce(this.grid.message("not_editable", { count: skipped }));
    if (firstProblem) this.grid.announce(firstProblem);
    if (drafted || firstProblem) this.grid.refreshRows();
    this.send(edits, "edit", origin);
  }

  private send(edits: Edit[], mode: "edit" | "undo" | "redo", origin: string = mode): void {
    if (edits.length === 0) return;
    for (const edit of edits) {
      const key = cellKey(edit.id, edit.key);
      this.errors.delete(key);
      this.saving.add(key);
    }
    this.grid.refreshRows();

    // Each edit says what the person saw: the server refuses it when the
    // cell changed meanwhile (see Masu.Edit).
    // A form's edit says the version of the value it opened with instead.
    const payload = edits.map((edit) =>
      edit.form ? { id: edit.id, key: edit.key, value: edit.value, version: edit.form.version ?? undefined } : { id: edit.id, key: edit.key, value: edit.value, before: edit.before },
    );
    this.inFlight++;
    this.grid.transport.push("masu:edit", { edits: payload, origin }, (reply) => {
      this.inFlight--;
      const errors = (reply.errors as [unknown, string, string, CellValue?][]) ?? [];
      // Cells saved later (Masu.Write.async/1) stay saving until the reply.
      const later = new Set(((reply.saving as [unknown, string][]) ?? []).map(([id, key]) => cellKey(id, key)));
      const now = edits.filter((edit) => !later.has(cellKey(edit.id, edit.key)));
      if (typeof reply.async === "string" && later.size > 0) {
        this.grid.later.set(reply.async, { kind: "edits", edits: edits.filter((edit) => later.has(cellKey(edit.id, edit.key))), mode });
        if (errors.length === 0) this.grid.announce(this.grid.message("saving_later", {}));
      }
      if (now.length > 0 || errors.length > 0) this.takeEditReply(now, errors, mode);
      else this.grid.refreshRows();
    });
  }

  /** The answer to edits: the cells refused show their old values (or their values now), with their errors. */
  takeEditReply(edits: Edit[], errors: [unknown, string, string, CellValue?][], mode: "edit" | "undo" | "redo"): void {
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
        const column = this.grid.columns[edit.col];
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
      const column = this.grid.columns.find((c) => c.key === key);
      const more = errors.length > 1 ? ` ${this.grid.message("more_errors", { count: errors.length - 1 })}` : "";
      this.grid.announce(`${column?.label ?? key}: ${message}${more}`);
      void id;
    } else if (edits.length > 1) {
      this.grid.announce(this.grid.message("saved", { count: saved.length }));
    }
    this.grid.refreshRows();

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
    else if (step?.kind === "delete") this.grid.deleting.restoreRows(step.undo);
  }

  private redo(): void {
    if (this.redoStack.length === 0 && this.inFlight > 0) {
      this.waiting.push("redo");
      return;
    }
    const step = this.redoStack.pop();
    if (step?.kind === "edits") this.send(step.edits.map((edit) => this.reverse(edit)), "redo");
    else if (step?.kind === "restore") this.grid.deleting.pushDelete({ ids: step.ids }, true);
  }

  /** The edit that takes `edit` back. */
  private reverse(edit: Edit): Edit {
    // A form's edit: back to what the form posted when it opened.
    if (edit.form) return { ...edit, value: edit.form.before, row: undefined, form: { before: edit.value, version: null } };
    const column = this.grid.columns[edit.col];
    const value = edit.before === null ? null : typeof edit.before === "boolean" ? edit.before : sendValue(column.type, inputText(column.type, edit.before), undefined);
    return { ...edit, before: shownValue(column.type, edit.value as string | boolean | null), value, row: undefined };
  }

  private clearCells(): void {
    const selection = this.grid.selection();
    if (!selection) return;
    this.withRows(selection, (cells) => this.applyEdits(cells.map(({ row, col }) => ({ row, col, value: null })), "clear"));
  }

  private fillDown(): void {
    const selection = this.grid.selection();
    if (!selection || selection.bottom === selection.top) return;
    this.withRows(selection, (cells) => {
      const edits = cells
        .filter(({ row }) => row !== selection.top)
        .map(({ row, col }) => {
          const column = this.grid.columns[col];
          const top = this.valueAt(selection.top, col) ?? null;
          const value = typeof top === "boolean" || top === null ? top : sendValue(column.type, inputText(column.type, top), undefined);
          return { row, col, value };
        });
      this.applyEdits(edits, "fill");
    });
  }

  onPaste(event: ClipboardEvent): void {
    if (document.activeElement !== this.grid.gridEl || this.editor) return;
    const text = event.clipboardData?.getData("text/plain");
    if (!text) return;
    event.preventDefault();
    const selection = this.grid.selection() ?? { top: 0, left: 0, bottom: 0, right: 0 };
    const matrix = fromTSV(text);
    // On the new rows: their values, and more new rows for more lines.
    if (selection.top >= this.grid.span() && this.grid.config.creates) {
      this.grid.newRows.pasteIntoDrafts(matrix, selection);
      return;
    }
    // Lines past the last row: new rows, if the person wants them.
    const single = matrix.length === 1 && matrix[0].length === 1;
    const overflow = single || !this.grid.exact ? 0 : Math.min(matrix.length - (this.grid.total - selection.top), MAX_NEW_ROWS);
    if (overflow > 0 && this.grid.config.creates) {
      this.grid.deleting.confirm(this.grid.message("paste_add", { count: overflow }), this.grid.message("add_rows", {}), () =>
        this.grid.newRows.addPastedRows(matrix.slice(matrix.length - overflow), selection.left),
      );
    }
    const placed = placePaste(matrix, selection, this.grid.span(), this.grid.columns.length).slice(0, MAX_EDITS);
    if (placed.length === 0) return;
    const bottom = Math.max(...placed.map((p) => p.row));
    const right = Math.max(...placed.map((p) => p.col));
    this.grid.anchor = { row: selection.top, col: selection.left };
    this.grid.active = { row: bottom, col: right };
    this.grid.load(selection.top, bottom, () => {
      const locale = this.grid.config.locale ?? undefined;
      this.applyEdits(
        placed.map((p) => ({ row: p.row, col: p.col, value: sendValue(this.grid.columns[p.col].type, p.text, locale) })),
        "paste",
      );
    });
  }

  /** The editable cells of a range, once the browser has its rows. */
  private withRows(range: Rect, then: (cells: Cell[]) => void): void {
    const last = Math.min(range.bottom, range.top + Math.floor(MAX_EDITS / (range.right - range.left + 1)) - 1);
    this.grid.load(range.top, last, () => {
      const cells: Cell[] = [];
      for (let row = range.top; row <= last; row++) {
        for (let col = range.left; col <= range.right; col++) {
          if (this.grid.columns[col].editable) cells.push({ row, col });
        }
      }
      then(cells);
    });
  }

  /** Whether the row's state makes its cell of `col` read-only; a group's row is. */
  locked(data: Row, col: number): boolean {
    if (isGroup(data)) return true;
    if (isDraft(data)) return !this.grid.columns[col]?.creatable;
    if (!this.grid.config.locks) return false;
    const lock = (data as unknown[])[this.grid.columns.length + 1];
    return lock === true || (Array.isArray(lock) && lock.includes(col));
  }

  private valueAt(row: number, col: number): CellValue | undefined {
    const data = this.grid.dataAt(row);
    return data ? rawValue(data[col + 1]) : undefined;
  }

  /** Puts a value in a row the browser has, in a new copy of the row. */
  private setValue(row: number, col: number, value: unknown): void {
    if (this.grid.draftAt(row)) return;
    for (const cache of [this.grid.cache, this.grid.stale]) {
      const data = cache?.get(row);
      if (!cache || !data) continue;
      const copy = [...data] as Row;
      copy[col + 1] = value as CellValue;
      cache.store(row, [copy]);
    }
  }
}
