// The rows the browser has: blocks of `size` rows, asked of the server
// one block at a time. A block may be partial (the server's first rows,
// or the last block of the query); a row it lacks is missing. The cache
// keeps at most `maxBlocks` blocks, and forgets those farthest from the
// rows on the screen.

import type { Row } from "./types";

export class BlockCache {
  readonly size: number;
  readonly maxBlocks: number;
  private blocks = new Map<number, (Row | undefined)[]>();
  private pending = new Set<number>();

  constructor(size = 100, maxBlocks = 60) {
    this.size = size;
    this.maxBlocks = maxBlocks;
  }

  clear(): void {
    this.blocks.clear();
    this.pending.clear();
  }

  blockOf(index: number): number {
    return Math.floor(index / this.size);
  }

  get(index: number): Row | undefined {
    return this.blocks.get(this.blockOf(index))?.[index % this.size];
  }

  /** Stores rows from row `from`, which may span blocks. */
  store(from: number, rows: Row[]): void {
    rows.forEach((row, i) => {
      const index = from + i;
      const block = this.blockOf(index);
      let rowsOf = this.blocks.get(block);
      if (!rowsOf) {
        rowsOf = [];
        this.blocks.set(block, rowsOf);
      }
      rowsOf[index % this.size] = row;
    });
    for (let block = this.blockOf(from); block <= this.blockOf(from + Math.max(rows.length - 1, 0)); block++) {
      this.pending.delete(block);
    }
  }

  /** Marks a block as asked for, until `store` or `failed`. */
  ask(block: number): void {
    this.pending.add(block);
  }

  failed(block: number): void {
    this.pending.delete(block);
  }

  /**
   * The blocks with a missing row among rows `first` to `last` (of
   * `total`) that are not asked for yet, nearest to `first` first.
   */
  missing(first: number, last: number, total: number): number[] {
    const end = Math.min(last, total - 1);
    if (end < 0 || first > end) return [];
    const blocks: number[] = [];
    for (let block = this.blockOf(Math.max(first, 0)); block <= this.blockOf(end); block++) {
      if (this.pending.has(block)) continue;
      const start = block * this.size;
      const stop = Math.min(start + this.size, total);
      const rows = this.blocks.get(block);
      let complete = rows !== undefined;
      for (let i = start; complete && i < stop; i++) {
        if (rows![i - start] === undefined) complete = false;
      }
      if (!complete) blocks.push(block);
    }
    return blocks;
  }

  /** Forgets the blocks farthest from `center` while there are too many. */
  evict(center: number): void {
    if (this.blocks.size <= this.maxBlocks) return;
    const far = [...this.blocks.keys()].sort((a, b) => Math.abs(b - center) - Math.abs(a - center));
    for (const block of far.slice(0, this.blocks.size - this.maxBlocks)) this.blocks.delete(block);
  }

  get blockCount(): number {
    return this.blocks.size;
  }
}
