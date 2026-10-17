// Where rows are when some of them have their detail open: a row is
// `rowHeight` tall, and an open detail adds a gap of its own height
// under its row. The gaps are few; each function walks them in order.

/** An open detail: under the row at `index`, `height` pixels tall. */
export interface Gap {
  index: number;
  height: number;
}

/** The top of the row at `index`. */
export function rowTop(index: number, rowHeight: number, gaps: Gap[]): number {
  let top = index * rowHeight;
  for (const gap of gaps) {
    if (gap.index >= index) break;
    top += gap.height;
  }
  return top;
}

/** The height of `total` rows and their gaps. */
export function totalHeight(total: number, rowHeight: number, gaps: Gap[]): number {
  return rowTop(total, rowHeight, gaps.filter((gap) => gap.index < total));
}

/** The row at `y`: the row whose top is at or above it (a gap belongs to the row above it). */
export function indexAt(y: number, rowHeight: number, gaps: Gap[]): number {
  let offset = 0;
  for (const gap of gaps) {
    const start = (gap.index + 1) * rowHeight + offset;
    if (y < start) break;
    if (y < start + gap.height) return gap.index;
    offset += gap.height;
  }
  return Math.max(0, Math.floor((y - offset) / rowHeight));
}
