// The rows the grid draws that are not the query's: new rows not saved
// yet, and a group's row; and the keys and values of cells.

import type { CellValue, Row } from "./types";

/** A new row's id, until it saves: a string of its own. */
export const DRAFT = "\u0000masu-draft:";

/** A new row, not saved yet. */
export function isDraft(row: Row): boolean {
  return typeof row[0] === "string" && row[0].startsWith(DRAFT);
}

/** A group's row (Masu.Group): its id is its path, `["masu-group", key, value, ...]`. */
export function isGroup(row: Row): boolean {
  const id = row[0];
  return Array.isArray(id) && id[0] === "masu-group";
}

export function cellKey(id: unknown, key: string): string {
  return `${JSON.stringify(id)}\u0000${key}`;
}

/** The value of a cell: an editable column of HEEx sends [html, value]. */
export function rawValue(value: unknown): CellValue {
  return Array.isArray(value) ? (value[1] as CellValue) : (value as CellValue);
}
