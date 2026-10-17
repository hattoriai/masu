import { test } from "node:test";
import assert from "node:assert/strict";
import { nextSorts } from "../src/sorting";

test("a click sorts by the column alone: ascending, descending, then none", () => {
  assert.deepEqual(nextSorts([], "name", false), [{ key: "name", dir: "asc" }]);
  assert.deepEqual(nextSorts([{ key: "name", dir: "asc" }], "name", false), [{ key: "name", dir: "desc" }]);
  assert.deepEqual(nextSorts([{ key: "name", dir: "desc" }], "name", false), []);
  assert.deepEqual(
    nextSorts([{ key: "age", dir: "desc" }, { key: "name", dir: "asc" }], "name", false),
    [{ key: "name", dir: "asc" }],
  );
});

test("a click with Shift adds, turns and takes away a column, keeping the others", () => {
  const age = { key: "age", dir: "desc" as const };
  assert.deepEqual(nextSorts([age], "name", true), [age, { key: "name", dir: "asc" }]);
  assert.deepEqual(nextSorts([age, { key: "name", dir: "asc" }], "name", true), [age, { key: "name", dir: "desc" }]);
  assert.deepEqual(nextSorts([age, { key: "name", dir: "desc" }], "name", true), [age]);
});
