// What the server sends: the grid's configuration (data-masu) and the
// answers to its events (see Masu.Grid).

export type CellValue = string | number | boolean | null;

/** A row as the server sends it: its id, then a value for each column. */
export type Row = [unknown, ...CellValue[]];

export type ColumnType =
  | "text"
  | "enum"
  | "integer"
  | "number"
  | "decimal"
  | "date"
  | "datetime"
  | "time"
  | "boolean";

export interface ColumnConfig {
  key: string;
  label: string;
  type: ColumnType;
  width: number;
  minWidth: number;
  align: "start" | "center" | "end";
  sortable: boolean;
  filterable: boolean;
  /** The server renders the cell's HTML. */
  html: boolean;
}

export interface SortSpec {
  key: string;
  dir: "asc" | "desc";
}

export interface FilterSpec {
  key: string;
  op: string;
  value?: unknown;
}

export interface QuerySpec {
  sorts: SortSpec[];
  filters: FilterSpec[];
  search: string | null;
}

export interface Config {
  v: number;
  columns: ColumnConfig[];
  rowHeight: number;
  total: number;
  revision: number;
  query: QuerySpec;
  locale: string | null;
  searchable: boolean;
  messages: Record<string, string>;
  initial: { from: number; rows: Row[] } | null;
}

export interface BlockReply {
  from: number;
  rows: Row[];
  total: number;
  revision: number;
  query?: QuerySpec;
  error?: string;
}

export interface Transport {
  push(event: string, payload: object, onReply?: (reply: Record<string, unknown>) => void): void;
}
