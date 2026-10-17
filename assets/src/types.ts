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
  editable: boolean;
  /** A new row takes a value in it (`create`). */
  creatable?: boolean;
  /** The values of an enum, which its editor offers; null when the column's values are any. */
  values?: CellValue[] | null;
  /** The digits after the point a number shows, whatever the value has. */
  decimals?: number | null;
  /** The server renders the cell's HTML (with the value, `[html, value]`, when editable). */
  html: boolean;
  /** Kept in view while the others scroll sideways. */
  pinned: "start" | "end" | null;
  /** How the column totals (Masu.Group): sum, avg, min, max, count, count_distinct, custom. */
  aggregate?: string | null;
}

/** A column of the grid, shown or not, as the columns menu lists it. */
export interface CatalogColumn {
  key: string;
  label: string;
  type: ColumnType;
  hidden: boolean;
  pinned: "start" | "end" | null;
  filterable: boolean;
  width: number;
}

/** A named view of the views menu (Masu.Views). */
export interface SavedView {
  id: string;
  name: string;
  shared: boolean;
  mine: boolean;
  current: boolean;
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
  /** The keys of the columns the rows are grouped by (Masu.Group). */
  groups?: string[];
}

export interface Config {
  v: number;
  columns: ColumnConfig[];
  rowHeight: number;
  total: number;
  /** The total is the query's count; else the rows read, and maybe more. */
  exact?: boolean;
  /** "scroll", or "pages" (`paging={:pages}`): a page of rows at a time. */
  paging?: "scroll" | "pages";
  pageSize: number;
  /** The rows of one read of the server: a page's, in a grid of pages. */
  blockSize?: number;
  /** The page, from 0. */
  page: number;
  revision: number;
  query: QuerySpec;
  locale: string | null;
  searchable: boolean;
  /** The ids of the rows that changed in this revision (Masu.Live). */
  changed: unknown[];
  /** Rows end with their read-only cells: `true`, or column indexes. */
  locks: boolean;
  /** The rows that changed by someone's edit, with their color. */
  changedBy: Record<string, string>;
  /** The grid shows who else has it open (Masu.Presence). */
  presence: boolean;
  messages: Record<string, string>;
  initial: { from: number; rows: Row[] } | null;
  /** Every column, in the layout's order, hidden ones too. */
  catalog: CatalogColumn[];
  /** The grid has a columns menu. */
  columnsMenu: boolean;
  /** The named views; null for a grid that keeps none. */
  views: SavedView[] | null;
  /** The parts of a view that no longer apply: [an id, the columns' keys]. */
  notice: [number, string] | null;
  /** The rows are a tree (Masu.Tree): each ends with its place in it. */
  tree: boolean;
  /** The rows open on a detail (the `:detail` slot). */
  detail: boolean;
  /** The open details: [row id, its index in the person's order]. */
  details: [unknown, number][];
  /** The totals of the query by column key, or null: no column totals. */
  totals: Record<string, CellValue> | null;
  /** The person may group the rows by a column (not a tree). */
  groupable: boolean;
  /** The formats of the Export menu ("csv", "xlsx"); empty without one. */
  export: string[];
  /** The rows selected (`selectable`): some ids, or every row of the query less some; null when rows do not select. */
  selection: { all: boolean; ids: unknown[]; except: unknown[]; count: number; exact?: boolean } | null;
  /** The person adds rows (`create`). */
  creates?: boolean;
  /** The person deletes rows (`delete`, `deletable`). */
  deletes?: boolean;
  /** A delete can be undone. */
  restores?: boolean;
}

export interface BlockReply {
  from: number;
  rows: Row[];
  total: number;
  exact?: boolean;
  revision: number;
  query?: QuerySpec;
  error?: string;
}

export interface Transport {
  push(event: string, payload: object, onReply?: (reply: Record<string, unknown>) => void): void;
}

/** Another person who has the grid open (Masu.Presence). */
export interface Person {
  id: string;
  name: string | null;
  color: string;
  /** Where they are: a row's id and a column's key. */
  cell: [unknown, string] | null;
  /** The range they selected: its rows' ids and its columns' keys. */
  range: { rows: unknown[]; keys: string[] } | null;
  editing: boolean;
  /** Their order, filters and search; null when their grid keeps them (`share_view={false}`). */
  view: QuerySpec | null;
  /** The id of the first row on their screen. */
  top: unknown;
}

export interface Options {
  /** Draws the label of a person on their cell: text, or an element. */
  peerLabel?: (person: Person) => string | HTMLElement;
}
