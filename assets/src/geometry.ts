// Where the rows and cells are: the rows on the screen, the moves of the
// keyboard, and the range between two cells. Rows count from 0; row -1
// is the header.

export interface Cell {
  row: number;
  col: number;
}

export interface Rect {
  top: number;
  left: number;
  bottom: number;
  right: number;
}

/**
 * The rows that a viewport of `height` pixels shows from `scrollTop`
 * (both measured from the first row), with `overscan` rows more on each
 * side. `last` is below `first` when there are no rows.
 */
export function visibleRows(
  scrollTop: number,
  height: number,
  rowHeight: number,
  total: number,
  overscan = 0,
): { first: number; last: number } {
  if (total <= 0) return { first: 0, last: -1 };
  const top = Math.max(0, scrollTop);
  const first = Math.max(0, Math.floor(top / rowHeight) - overscan);
  const last = Math.min(total - 1, Math.ceil((top + Math.max(height, 0)) / rowHeight) - 1 + overscan);
  return { first: Math.min(first, total - 1), last: Math.max(last, Math.min(first, total - 1)) };
}

export interface MoveContext {
  rows: number;
  cols: number;
  /** Rows on a page, for Page Up and Page Down. */
  page: number;
  /** The grid reads right to left: the arrows swap. */
  rtl?: boolean;
}

/**
 * The cell that a key moves to from `cell`, or `null` for a key that does
 * not move. `mod` is Ctrl (⌘ on a Mac).
 */
export function move(cell: Cell, key: string, mod: boolean, ctx: MoveContext): Cell | null {
  const lastRow = ctx.rows - 1;
  const lastCol = ctx.cols - 1;
  const left = ctx.rtl ? "ArrowRight" : "ArrowLeft";
  const right = ctx.rtl ? "ArrowLeft" : "ArrowRight";
  let { row, col } = cell;

  switch (key) {
    case "ArrowUp":
      row = mod ? -1 : row - 1;
      break;
    case "ArrowDown":
      row = mod ? lastRow : row + 1;
      break;
    case left:
      col = mod ? 0 : col - 1;
      break;
    case right:
      col = mod ? lastCol : col + 1;
      break;
    case "Home":
      if (mod) row = row < 0 ? -1 : 0;
      col = 0;
      break;
    case "End":
      if (mod) row = row < 0 ? -1 : lastRow;
      col = lastCol;
      break;
    case "PageUp":
      row = row < 0 ? -1 : row - Math.max(ctx.page, 1);
      if (cell.row >= 0) row = Math.max(row, 0);
      break;
    case "PageDown":
      row = row + Math.max(ctx.page, 1);
      break;
    default:
      return null;
  }

  return {
    row: Math.min(Math.max(row, -1), Math.max(lastRow, -1)),
    col: Math.min(Math.max(col, 0), Math.max(lastCol, 0)),
  };
}

/** The rectangle between two cells, both included. */
export function rect(a: Cell, b: Cell): Rect {
  return {
    top: Math.min(a.row, b.row),
    left: Math.min(a.col, b.col),
    bottom: Math.max(a.row, b.row),
    right: Math.max(a.col, b.col),
  };
}

export function contains(r: Rect, row: number, col: number): boolean {
  return row >= r.top && row <= r.bottom && col >= r.left && col <= r.right;
}
