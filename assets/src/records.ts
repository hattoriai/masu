// The records of the grid's own state: the editor of a cell, the edits it
// makes and undoes, new rows, and the history of a cell.

import type { Cell } from "./geometry";
import type { FormValue } from "./forms";
import type { CellEditor, CellValue, QuerySpec, Row } from "./types";

export interface Editor {
  input: HTMLInputElement;
  /** What the editor is drawn in: its input, or the box of an editor of the app's. */
  el: HTMLElement;
  /** An editor of the app's (`configure({editors})`). */
  own: CellEditor | null;
  row: number;
  col: number;
  id: unknown;
  original: CellValue;
  done: boolean;
  /** An enum's list of values, and those it shows, and the one picked. */
  list: HTMLElement | null;
  options: string[];
  shown: string[];
  highlight: number;
}

export interface OwnView {
  query: QuerySpec;
  scrollTop: number;
  scrollLeft: number;
  active: Cell;
  anchor: Cell | null;
}

export interface Edit {
  id: unknown;
  key: string;
  col: number;
  /** The row's index when the edit was made; undefined for an undo. */
  row: number | undefined;
  before: CellValue;
  /** What a form posts is params: text, and maps and lists of it. */
  value: string | boolean | null | FormValue;
  /** An edit of a form of the app's: what it posted when it opened, and the version of the value it opened with. */
  form?: { before: FormValue | string | boolean | null; version: number | null };
}

/** A cell edited with a form of the app's, in a popover the server renders. */
export interface FormEditor {
  row: number;
  col: number;
  id: unknown;
  key: string;
  /** The version of the value it opened with; null until the server says. */
  version: number | null;
  /** What its form posted when it opened. */
  initial: FormValue | undefined;
  wired: boolean;
  done: boolean;
}

export const MAX_EDITS = 5_000;

/** The most rows added or deleted at once (Masu.Edit). */
export const MAX_NEW_ROWS = 1_000;

/** A new row: its values by column key, as they go to the server. */
export interface Draft {
  id: string;
  values: Map<string, string | boolean | null>;
  row: Row;
  saving: boolean;
}

/** A step to undo or redo: edits of cells, a delete, or a delete undone. */
export type Step = { kind: "edits"; edits: Edit[] } | { kind: "delete"; undo: string } | { kind: "restore"; ids: unknown[] };

/** A write or an action that goes on later, until its reply (Masu.reply/2). */
export type Later =
  | { kind: "edits"; edits: Edit[]; mode: "edit" | "undo" | "redo" }
  | { kind: "delete"; count: number }
  | { kind: "action"; label: string };

/** An entry of the history of a cell or a row (Masu.History). */
export interface HistoryEntry {
  id: string | null;
  key: string | null;
  op: "update" | "create" | "delete";
  before: unknown;
  after: unknown;
  user: string | null;
  origin: string;
  batch: string | null;
  batch_size: number;
  at: string;
}

/** The origins of an entry that its line says (a paste, a restore...). */
export const HISTORY_ORIGINS = ["paste", "fill", "clear", "undo", "redo", "restore"];

export const MOVES = { down: { row: 1, col: 0 }, up: { row: -1, col: 0 }, right: { row: 0, col: 1 }, left: { row: 0, col: -1 } };

/** A row's element, with its place and its row. */
export interface RowElement extends HTMLDivElement {
  masuIndex?: number;
  masuRow?: Row | null;
  masuTop?: number;
}

/** A row's place in a tree (Masu.Tree), after its cells. */
export interface TreeNode {
  level: number;
  children: boolean;
  expanded: boolean;
  position: number;
  size: number;
}
