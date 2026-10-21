// A person's view: their order, filters and search (the query's wire
// form). Following someone shows their view (its Issho room).

import type { QuerySpec } from "./types";

/** Whether two views show the same rows in the same order. */
export function sameView(a: QuerySpec, b: QuerySpec): boolean {
  return JSON.stringify(normal(a)) === JSON.stringify(normal(b));
}

function normal(view: QuerySpec): QuerySpec {
  const search = view.search?.trim() ? view.search.trim() : null;
  const filters = [...view.filters].sort((x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0));
  return { sorts: view.sorts, filters, search, groups: view.groups ?? [] };
}
