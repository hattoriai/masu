import { test } from "node:test";
import assert from "node:assert/strict";
import { contains, move, rect, visibleRows } from "../src/geometry";

test("visibleRows() gives the rows on the screen, with the overscan", () => {
  assert.deepEqual(visibleRows(0, 360, 36, 1000), { first: 0, last: 9 });
  assert.deepEqual(visibleRows(3600, 360, 36, 1000, 5), { first: 95, last: 114 });
  assert.deepEqual(visibleRows(18, 360, 36, 1000), { first: 0, last: 10 });
  assert.deepEqual(visibleRows(0, 360, 36, 4), { first: 0, last: 3 });
  assert.deepEqual(visibleRows(99999, 360, 36, 4), { first: 3, last: 3 });
  assert.deepEqual(visibleRows(0, 360, 36, 0), { first: 0, last: -1 });
});

const ctx = { rows: 100, cols: 5, page: 10 };

test("the arrows move one cell, and stop at the edges and the header", () => {
  assert.deepEqual(move({ row: 5, col: 2 }, "ArrowDown", false, ctx), { row: 6, col: 2 });
  assert.deepEqual(move({ row: 0, col: 2 }, "ArrowUp", false, ctx), { row: -1, col: 2 });
  assert.deepEqual(move({ row: -1, col: 2 }, "ArrowUp", false, ctx), { row: -1, col: 2 });
  assert.deepEqual(move({ row: 99, col: 4 }, "ArrowDown", false, ctx), { row: 99, col: 4 });
  assert.deepEqual(move({ row: 3, col: 0 }, "ArrowLeft", false, ctx), { row: 3, col: 0 });
  assert.deepEqual(move({ row: 3, col: 0 }, "ArrowRight", false, ctx), { row: 3, col: 1 });
  assert.deepEqual(move({ row: 3, col: 1 }, "ArrowRight", false, { ...ctx, rtl: true }), { row: 3, col: 0 });
});

test("Home, End, the pages and Ctrl jump", () => {
  assert.deepEqual(move({ row: 3, col: 3 }, "Home", false, ctx), { row: 3, col: 0 });
  assert.deepEqual(move({ row: 3, col: 3 }, "End", true, ctx), { row: 99, col: 4 });
  assert.deepEqual(move({ row: 3, col: 3 }, "Home", true, ctx), { row: 0, col: 0 });
  assert.deepEqual(move({ row: 3, col: 3 }, "PageDown", false, ctx), { row: 13, col: 3 });
  assert.deepEqual(move({ row: 3, col: 3 }, "PageUp", false, ctx), { row: 0, col: 3 });
  assert.deepEqual(move({ row: 95, col: 3 }, "PageDown", false, ctx), { row: 99, col: 3 });
  assert.deepEqual(move({ row: 50, col: 3 }, "ArrowDown", true, ctx), { row: 99, col: 3 });
  assert.equal(move({ row: 1, col: 1 }, "a", false, ctx), null);
});

test("a grid with no rows keeps the header", () => {
  assert.deepEqual(move({ row: -1, col: 1 }, "ArrowDown", false, { rows: 0, cols: 3, page: 10 }), { row: -1, col: 1 });
});

test("rect() and contains() make a range of two cells", () => {
  const r = rect({ row: 9, col: 1 }, { row: 2, col: 3 });
  assert.deepEqual(r, { top: 2, left: 1, bottom: 9, right: 3 });
  assert.ok(contains(r, 5, 2));
  assert.ok(!contains(r, 10, 2));
  assert.ok(!contains(r, 5, 0));
});
