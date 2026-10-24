// The grid's config, as the server sends it on its element, and what the
// grid derives from it.

import { BlockCache } from "./blocks";
import type { ColumnConfig, Config } from "./types";

/**
 * The rows the browser keeps, in blocks of the server's size (a page's, in
 * a grid of pages): about six thousand rows, however large a block.
 */
export function cacheFor(config: Config): BlockCache {
  const size = Math.max(1, config.blockSize ?? 100);
  return new BlockCache(size, Math.max(3, Math.ceil(6000 / size)));
}

export function keysOf(columns: ColumnConfig[]): string {
  return columns.map((column) => column.key).join("\u0000");
}

export function withoutWidths(columns: ColumnConfig[]): Omit<ColumnConfig, "width">[] {
  return columns.map(({ width: _width, ...column }) => column);
}

/** The grid's config, and its words, which come apart so that they are sent once, not with each change of the config. */
export function readConfig(el: HTMLElement): Config {
  const config = JSON.parse(el.dataset.masu ?? "{}") as Config;
  return { ...config, messages: JSON.parse(el.dataset.masuMessages ?? "{}") as Record<string, string> };
}
