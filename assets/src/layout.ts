// The layout of the columns in the browser: where pinned columns stick,
// where a cell is on the screen, and moving a column.

export type Pin = "start" | "end" | null;

export interface Pins {
  /** The offset of each column pinned to the start, from the start. */
  start: Map<number, number>;
  /** The offset of each column pinned to the end, from the end. */
  end: Map<number, number>;
  /** The width of the pinned columns at the start, and at the end. */
  startWidth: number;
  endWidth: number;
}

/** Where the pinned columns stick: the server puts them first and last. */
export function pins(pinned: Pin[], widths: number[]): Pins {
  const start = new Map<number, number>();
  const end = new Map<number, number>();
  let left = 0;
  pinned.forEach((pin, col) => {
    if (pin === "start") {
      start.set(col, left);
      left += widths[col];
    }
  });
  let right = 0;
  for (let col = pinned.length - 1; col >= 0; col--) {
    if (pinned[col] === "end") {
      end.set(col, right);
      right += widths[col];
    }
  }
  return { start, end, startWidth: left, endWidth: right };
}

/**
 * Where a column's cells are, from the start of the rows, with the grid
 * scrolled sideways by `scroll` in a box `view` wide: a pinned column
 * sticks to its edge.
 */
export function visualLeft(col: number, widths: number[], layout: Pins, scroll: number, view: number): number {
  const natural = widths.slice(0, col).reduce((a, b) => a + b, 0);
  const start = layout.start.get(col);
  if (start !== undefined) return Math.max(natural, scroll + start);
  const end = layout.end.get(col);
  if (end !== undefined) return Math.min(natural, scroll + view - end - widths[col]);
  return natural;
}

/**
 * The scroll that shows a column, or null when it shows: the pinned
 * columns cover the edges of the box.
 */
export function scrollFor(col: number, widths: number[], layout: Pins, scroll: number, view: number): number | null {
  if (layout.start.has(col) || layout.end.has(col)) return null;
  const left = widths.slice(0, col).reduce((a, b) => a + b, 0);
  const right = left + widths[col];
  if (left < scroll + layout.startWidth) return Math.max(0, left - layout.startWidth);
  if (right > scroll + view - layout.endWidth) return right - view + layout.endWidth;
  return null;
}

/**
 * The widths the columns are drawn at in a box `room` wide: the room the
 * columns leave goes to those that grow, each its share (`grow`), in
 * whole pixels, the last taking what the rounding leaves. A box narrower
 * than the columns leaves them as they are (it scrolls).
 */
export function fill(widths: number[], grow: number[], room: number): number[] {
  const spare = Math.floor(room - widths.reduce((a, b) => a + b, 0));
  const shares = grow.reduce((a, b) => a + (b > 0 ? b : 0), 0);
  if (spare <= 0 || shares === 0) return widths.slice();
  let given = 0;
  let last = -1;
  const filled = widths.map((width, col) => {
    if (!(grow[col] > 0)) return width;
    const extra = Math.floor((spare * grow[col]) / shares);
    given += extra;
    last = col;
    return width + extra;
  });
  filled[last] += spare - given;
  return filled;
}

/** The keys with `key` moved before `before` (null: to the end). */
export function moveKey(order: string[], key: string, before: string | null): string[] {
  const rest = order.filter((k) => k !== key);
  const index = before === null ? rest.length : rest.indexOf(before);
  if (index < 0) return order;
  return [...rest.slice(0, index), key, ...rest.slice(index)];
}
