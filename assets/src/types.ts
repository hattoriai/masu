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
  /** Its share of the room the columns leave in a wider grid (`grow`); 0 or none: its width. */
  grow?: number;
  align: "start" | "center" | "end";
  sortable: boolean;
  filterable: boolean;
  /** The operators its source filters it by (Masu.Source's `filters/2`); null: every operator of its type. */
  filters?: string[] | null;
  /** Of many values (a path through several related rows): each cell's value is a list. */
  many?: boolean;
  editable: boolean;
  /** A new row takes a value in it (`create`). */
  creatable?: boolean;
  /** The values of an enum, which its editor offers; null when the column's values are any. */
  values?: CellValue[] | null;
  /** The digits after the point a number shows, whatever the value has. */
  decimals?: number | null;
  /** Its values as the server sends them, not formatted for the locale. */
  raw?: boolean;
  /** The server renders the cell's HTML (with the value, `[html, value]`, when editable). */
  html: boolean;
  /** Kept in view while the others scroll sideways. */
  pinned: "start" | "end" | null;
  /** How the column totals (Masu.Group): sum, avg, min, max, count, count_distinct, custom. */
  aggregate?: string | null;
  /** The app's items of its header menu (`:header_action`). */
  headerActions?: ActionItem[];
  /** The app's items of the menu of its cells (`:cell_action`). */
  cellActions?: ActionItem[];
  /** An editor of the app's own (`editor` on a `:col`): a form the server renders, or one of the browser's, by name. */
  editor?: { kind: "form" } | { kind: "js"; name: string; options: Record<string, unknown> } | null;
}

/** An item of a menu of the app's own (Masu.Action). */
export interface ActionItem {
  /** Its place among the items of its slot: what the server takes back. */
  id: number;
  label: string;
  /** It runs on the server (`on_action`, `event`). */
  server: boolean;
  /** A JS command for the browser to run, encoded. */
  js: string | null;
  /** It opens a panel that the server renders. */
  panel: boolean;
}

/**
 * An action of the app's on the rows selected (`:action`) or on a row
 * (`:row_action`), Masu.Action. A row says which of its row actions it
 * shows: `[id, disabled, href]` of each.
 */
export interface RowsAction {
  /** Its place among the actions of its slot: what the server takes back. */
  id: number;
  label: string;
  /** A row action that is a link: "navigate" or "patch", with the row's href. */
  link: "navigate" | "patch" | null;
  /** A question first ("Delete {count} orders?"). */
  confirm: string | null;
  /** It destroys. */
  danger: boolean;
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
  /** A grid of the height of its rows (`height="auto"`): the most they take, as CSS; else null. */
  autoHeight?: string | null;
  /** "page": the wheel scrolls the page until the person is in the grid. */
  wheel?: "grid" | "page";
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
  /** The grid shows who else has it open (its Issho room). */
  presence: boolean;
  /** Whether the grid takes part in following, the room's (false: it follows no one, and shows no one followed). */
  follow?: boolean;
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
  /** The built-in items of the menu of a cell: "copy", "filter", "sort". */
  cellMenu?: string[];
  /** The grid keeps a history of its cells (Masu.History). */
  history?: boolean;
  /** The app's actions on the rows selected (`:action`). */
  actions?: RowsAction[];
  /** The app's actions on a row (`:row_action`); each row carries its own state of them, after its read-only cells. */
  rowActions?: RowsAction[];
  /** A click on a row, or Enter on it, opens it (`on_row_activate`). */
  activates?: boolean;
  /** Rows to come: a read in a task (`load={:async}`), or the LiveView's own query (`on_query`). */
  running?: boolean;
  /** `false`: one sort at a time (`multi_sort={false}`). */
  multiSort?: boolean;
  /** `false`: no ranges of cells, by a drag, Shift or Ctrl+A (`range_select={false}`); a cell is selected alone. */
  rangeSelect?: boolean;
  /** The filter bar (`filter_bar`): Add filter above the grid, and a menu of sorts and filter on each header; false: the funnel on each header. */
  filterBar?: boolean;
  /** Whether a header's menu has the column's filter (`header_filters`); false: the filters are the filter bar's alone. */
  headerFilters?: boolean;
}

export interface BlockReply {
  from: number;
  rows: Row[];
  total: number;
  exact?: boolean;
  revision: number;
  query?: QuerySpec;
  error?: string;
  /** The rows come later: in a `masu:block` event, or with the server's next render. */
  pending?: boolean;
  /** A read in a task that failed: the grid shows its error. */
  failed?: boolean;
}

/** How a write or an action that went on later went (Masu.reply/2), or how far it is (Masu.progress/3). */
export interface Reply {
  token: string;
  ok: boolean;
  message: string | null;
  /** The cells (`[id, key, message]`) or rows (`[id, message]`) a write refused. */
  errors: unknown[][];
  revision: number;
  total: number;
}

export interface Progress {
  token: string;
  done: number;
  total: number;
}

export interface Transport {
  push(event: string, payload: object, onReply?: (reply: Record<string, unknown>) => void): void;
  /** Runs a JS command (Phoenix.LiveView.JS, encoded) on the grid's element. */
  exec?(js: string): void;
}

/** Another person who has the grid open (its Issho room). */
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
  /** Their pointer over a cell (its row's id and column's key, and where in it), or none. */
  pointer?: { cell: [unknown, string]; x: number; y: number } | null;
}

export interface Options {
  /** Draws the label of a person on their cell: text, or an element. */
  peerLabel?: (person: Person) => string | HTMLElement;
  /** Editors of the app's own, by name: a column with `editor="name"` edits with it. */
  editors?: Record<string, CellEditorFactory>;
}

/**
 * What an editor of the app's own gets (`configure({editors})`): the cell,
 * and where to draw. It draws in `element`, a box over the cell as wide as
 * its column and as tall as its row (it may grow), and says when it is
 * done with `commit` or `cancel`.
 *
 * The keys it handles, it prevents (`event.preventDefault()`): the grid
 * acts on the others, Enter and Tab (commit, and move), Escape (cancel).
 * The grid commits `value()` when the focus leaves the editor, and checks
 * a value by the column's type before it saves it, as it does for its own
 * editors; undo, conflicts, errors on the cell and "Ada is editing" are
 * the grid's.
 */
export interface CellEditorContext {
  /** The box to draw in, over the cell. */
  element: HTMLElement;
  /** The cell's value, as the browser has it. */
  value: CellValue;
  /** The character typed that opened the editor, if one did. */
  text: string | null;
  /** The row's id, and its values by column key. */
  id: unknown;
  row: Record<string, CellValue>;
  column: ColumnConfig;
  /** The options of the column's editor (`editor={{"name", %{...}}}`). */
  options: Record<string, unknown>;
  /** The name of the cell, for the editor's input (`aria-label`). */
  label: string;
  /** The grid's locale, when it has one. */
  locale: string | null;
  /** Saves a value; `move` goes to the next cell, as Enter or Tab do. */
  commit(value: CellValue, move?: "down" | "up" | "right" | "left"): void;
  /** Lets the edit go, as Escape does. */
  cancel(): void;
}

export interface CellEditor {
  /** Takes the focus; the first control of `element` takes it unless given. */
  focus?(): void;
  /** The value as it is now: what the grid saves when the focus leaves the editor. */
  value?(): CellValue;
  /** Whether a node is the editor's own, outside `element` (a list it put elsewhere). */
  contains?(node: Node): boolean;
  /** Called when the editor closes. */
  destroy?(): void;
}

export type CellEditorFactory = (context: CellEditorContext) => CellEditor;
