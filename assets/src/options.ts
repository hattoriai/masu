// The options of every grid of the page (`configure/1`).

import type { Options } from "./types";

export const options: Options = {};

/**
 * Options of every grid of the page: `peerLabel`, a function that draws
 * the label of another person on their cell (its Issho room).
 */
export function configure(next: Options): void {
  Object.assign(options, next);
}
