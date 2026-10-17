import { test } from "node:test";
import assert from "node:assert/strict";
import { sameView } from "../src/view";

const base = { sorts: [{ key: "name", dir: "asc" as const }], filters: [], search: null };

test("views with the same order, filters and search are the same", () => {
  assert.equal(sameView(base, { ...base }), true);
  assert.equal(sameView(base, { ...base, search: "" }), true);
  assert.equal(sameView(base, { ...base, search: "  " }), true);
});

test("the order of the filters does not matter, the order of the sorts does", () => {
  const a = { key: "plan", op: "eq", value: "team" };
  const b = { key: "city", op: "eq", value: "Oslo" };
  assert.equal(sameView({ ...base, filters: [a, b] }, { ...base, filters: [b, a] }), true);
  const two = [
    { key: "name", dir: "asc" as const },
    { key: "city", dir: "desc" as const },
  ];
  assert.equal(sameView({ ...base, sorts: two }, { ...base, sorts: [...two].reverse() }), false);
});

test("a different search, filter or direction is a different view", () => {
  assert.equal(sameView(base, { ...base, search: "ada" }), false);
  assert.equal(sameView(base, { ...base, sorts: [{ key: "name", dir: "desc" }] }), false);
  assert.equal(sameView(base, { ...base, filters: [{ key: "plan", op: "eq", value: "team" }] }), false);
});
