// What a click on a header does to the order. A click sorts by the
// column alone: ascending, then descending, then not at all. A click with
// Shift keeps the other columns, and adds the column at the end, turns
// it, or takes it away.

import type { SortSpec } from "./types";

export function nextSorts(sorts: SortSpec[], key: string, additive: boolean): SortSpec[] {
  const current = sorts.find((sort) => sort.key === key);

  if (!additive) {
    if (sorts.length === 1 && current?.dir === "asc") return [{ key, dir: "desc" }];
    if (sorts.length === 1 && current?.dir === "desc") return [];
    return [{ key, dir: "asc" }];
  }

  if (!current) return [...sorts, { key, dir: "asc" }];
  if (current.dir === "asc") return sorts.map((sort) => (sort.key === key ? { key, dir: "desc" } : sort));
  return sorts.filter((sort) => sort.key !== key);
}
