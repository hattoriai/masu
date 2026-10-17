import { test } from "node:test";
import assert from "node:assert/strict";
import { arity, describe, inputType, makeFilter, opsFor, replaceFilter } from "../src/filters";
import type { ColumnConfig } from "../src/types";

const column = (key: string, type: ColumnConfig["type"], label = key): ColumnConfig => ({
  key,
  label,
  type,
  width: 100,
  minWidth: 48,
  align: "start",
  sortable: true,
  filterable: true,
  editable: false,
  html: false,
});

const messages: Record<string, string> = {
  op_contains: "contains",
  op_in: "is one of",
  op_between: "between",
  op_is_nil: "is empty",
  op_eq: "is",
  op_gt_time: "after",
  and: "and",
  yes: "Yes",
  no: "No",
  empty_value: "(empty)",
};

test("each type offers its operators, the first the default", () => {
  assert.equal(opsFor("text")[0], "contains");
  assert.deepEqual(opsFor("enum"), ["in", "is_nil", "not_nil"]);
  assert.ok(opsFor("decimal").includes("between"));
  assert.ok(!opsFor("date").includes("contains"));
  assert.equal(inputType("datetime"), "datetime-local");
  assert.equal(inputType("decimal"), "number");
  assert.equal(arity("between"), 2);
  assert.equal(arity("not_nil"), 0);
});

test("makeFilter() reads the inputs, and makes nothing of empty ones", () => {
  assert.deepEqual(makeFilter(column("city", "text"), "contains", [" lon "]), { key: "city", op: "contains", value: "lon" });
  assert.equal(makeFilter(column("city", "text"), "contains", ["  "]), null);
  assert.deepEqual(makeFilter(column("age", "integer"), "between", ["20", "36"]), { key: "age", op: "between", value: ["20", "36"] });
  assert.equal(makeFilter(column("age", "integer"), "between", ["20", ""]), null);
  assert.deepEqual(makeFilter(column("plan", "enum"), "in", ["free", "team"]), { key: "plan", op: "in", value: ["free", "team"] });
  assert.equal(makeFilter(column("plan", "enum"), "in", []), null);
  assert.deepEqual(makeFilter(column("city", "text"), "is_nil", []), { key: "city", op: "is_nil" });
  assert.deepEqual(makeFilter(column("active", "boolean"), "eq", ["false"]), { key: "active", op: "eq", value: false });
});

test("describe() says a filter in words, with the column's format", () => {
  const upper = (value: unknown) => String(value).toUpperCase();
  assert.equal(describe({ key: "city", op: "contains", value: "lon" }, column("city", "text", "City"), upper, messages), "City contains LON");
  assert.equal(
    describe({ key: "plan", op: "in", value: ["free", null] }, column("plan", "enum", "Plan"), upper, messages),
    "Plan is one of FREE, (empty)",
  );
  assert.equal(describe({ key: "age", op: "between", value: ["20", "36"] }, column("age", "integer", "Age"), String, messages), "Age between 20 and 36");
  assert.equal(describe({ key: "city", op: "is_nil" }, column("city", "text", "City"), String, messages), "City is empty");
  assert.equal(describe({ key: "on", op: "gt", value: "2026-01-01" }, column("on", "date", "Day"), String, messages), "Day after 2026-01-01");
  assert.equal(describe({ key: "ok", op: "eq", value: false }, column("ok", "boolean", "Active"), String, messages), "Active is No");
});

test("replaceFilter() keeps one filter a column", () => {
  const filters = [{ key: "a", op: "eq", value: 1 }, { key: "b", op: "eq", value: 2 }];
  assert.deepEqual(replaceFilter(filters, "a", { key: "a", op: "gt", value: 5 }), [{ key: "b", op: "eq", value: 2 }, { key: "a", op: "gt", value: 5 }]);
  assert.deepEqual(replaceFilter(filters, "b", null), [{ key: "a", op: "eq", value: 1 }]);
});
