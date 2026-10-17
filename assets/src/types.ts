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
  /** The server renders the cell's HTML (with the value, `[html, value]`, when editable). */
  html: boolean;
  /** Kept in view while the others scroll sideways. */
  pinned: "start" | "end" | null;
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
