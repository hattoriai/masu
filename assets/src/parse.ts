// What a person types or pastes into cells: numbers in the grid's locale,
// tab-separated text from a spreadsheet, and the cells a paste or a fill
// lands on.

import type { CellValue, ColumnType } from "./types";
import type { Rect } from "./geometry";

/**
 * A number typed in `locale` ("1.234,5" in German) as the server reads it
 * ("1234.5"), or the text as it is when it is not one, so that the
 * server's changeset says what is wrong with it.
 */
export function parseNumber(text: string, locale: string | undefined): string {
  const trimmed = text.trim().replace(/\s/g, "");
  if (trimmed === "") return "";
  const parts = new Intl.NumberFormat(locale).formatToParts(12345.6);
  const group = parts.find((part) => part.type === "group")?.value ?? ",";
  const decimal = parts.find((part) => part.type === "decimal")?.value ?? ".";

  // A plain number ("1234.5") reads the same in every locale.
  if (/^-?\d+(\.\d+)?$/.test(trimmed)) return trimmed;

  const normalized = trimmed
    .replace(/−/g, "-")
    .split(group === " " || group === " " ? /[  ]/ : group)
    .join("")
    .replace(decimal, ".");
  return /^-?\d+(\.\d+)?$/.test(normalized) ? normalized : text.trim();
}

/** Tab-separated text, as spreadsheets copy it: rows of cells. */
export function fromTSV(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  let i = 0;
  const input = text.replace(/\r\n?/g, "\n");

  while (i < input.length) {
    const char = input[i];
    if (quoted) {
      if (char === '"' && input[i + 1] === '"') {
        cell += '"';
        i += 2;
        continue;
      }
      if (char === '"') {
        quoted = false;
        i += 1;
        continue;
      }
      cell += char;
      i += 1;
      continue;
    }
    if (char === '"' && cell === "") {
      quoted = true;
    } else if (char === "\t") {
      row.push(cell);
      cell = "";
    } else if (char === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += char;
    }
    i += 1;
  }
  if (cell !== "" || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

export interface Placed {
  row: number;
  col: number;
  text: string;
}

/**
 * The cells that pasted rows land on: from the top left of the selection,
 * as far as the rows and columns go (within the grid). One value pasted
 * on a selection of several cells fills them all, as a spreadsheet does.
 */
export function placePaste(matrix: string[][], selection: Rect, rows: number, cols: number): Placed[] {
  const placed: Placed[] = [];
  const single = matrix.length === 1 && matrix[0].length === 1;
  const height = single ? selection.bottom - selection.top + 1 : matrix.length;
  for (let r = 0; r < height; r++) {
    const row = selection.top + r;
    if (row >= rows) break;
    const line = single ? matrix[0] : matrix[r];
    const width = single ? selection.right - selection.left + 1 : line.length;
    for (let c = 0; c < width; c++) {
      const col = selection.left + c;
      if (col >= cols) break;
      placed.push({ row, col, text: single ? matrix[0][0] : line[c] });
    }
  }
  return placed;
}

/** The value of a cell as its editor shows it. */
export function inputText(type: ColumnType, value: CellValue): string {
  if (value === null || value === undefined) return "";
  if (type === "datetime" && typeof value === "string") return localDateTime(value);
  if (type === "time" && typeof value === "string") return value.slice(0, 8);
  return String(value);
}

/**
 * What an editor's text sends to the server, for a column of `type`: a
 * number read in the locale, a datetime with the browser's offset, a
 * boolean, or the text; `null` for an emptied cell.
 */
export function sendValue(type: ColumnType, text: string, locale: string | undefined): string | boolean | null {
  const trimmed = text.trim();
  if (trimmed === "") return null;
  switch (type) {
    case "integer":
    case "number":
    case "decimal":
      return parseNumber(trimmed, locale);
    case "boolean":
      return ["true", "1", "yes", "✓", "x", "TRUE"].includes(trimmed) || trimmed.toLowerCase() === "true";
    case "datetime": {
      const date = new Date(trimmed);
      return /(Z|[+-]\d{2}:?\d{2})$/.test(trimmed) || Number.isNaN(date.getTime()) ? trimmed : date.toISOString();
    }
    default:
      return text;
  }
}

/** The value a cell shows until the server answers. */
export function shownValue(type: ColumnType, sent: string | boolean | null): CellValue {
  if (sent === null || typeof sent === "boolean") return sent;
  if ((type === "integer" || type === "number") && /^-?\d+(\.\d+)?$/.test(sent)) return Number(sent);
  return sent;
}

// A datetime with a zone, in the browser's time, as a datetime-local
// input shows it; one without a zone as it is.
function localDateTime(value: string): string {
  if (!/(Z|[+-]\d{2}:?\d{2})$/.test(value)) return value.slice(0, 19);
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}
