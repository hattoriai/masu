import { test } from "node:test";
import assert from "node:assert/strict";
import { fill, moveKey, pins, scrollFor, visualLeft } from "../src/layout";

const widths = [80, 200, 100, 100, 120];
const layout = pins(["start", null, null, null, "end"], widths);

test("pinned columns stick at the sums of the widths before them, from their edge", () => {
  assert.deepEqual([...layout.start], [[0, 0]]);
  assert.deepEqual([...layout.end], [[4, 0]]);
  assert.equal(layout.startWidth, 80);
  assert.equal(layout.endWidth, 120);

  const two = pins(["start", "start", null, "end", "end"], widths);
  assert.deepEqual([...two.start], [[0, 0], [1, 80]]);
  assert.deepEqual([...two.end].sort(), [[3, 120], [4, 0]]);
});

test("a cell is where it is, unless its column sticks", () => {
  // Scrolled 150px in a box of 300px.
  assert.equal(visualLeft(0, widths, layout, 150, 300), 150);
  assert.equal(visualLeft(1, widths, layout, 150, 300), 80);
  assert.equal(visualLeft(4, widths, layout, 150, 300), 330);
  assert.equal(visualLeft(4, widths, layout, 300, 300), 480);
});

test("the scroll that shows a column leaves room for the pinned", () => {
  assert.equal(scrollFor(0, widths, layout, 150, 300), null);
  assert.equal(scrollFor(1, widths, layout, 150, 300), 0);
  assert.equal(scrollFor(3, widths, layout, 0, 300), 300);
  assert.equal(scrollFor(2, widths, layout, 200, 300), null);
  assert.equal(scrollFor(2, widths, layout, 150, 300), 200);
});

test("moving a key puts it before another, or last", () => {
  assert.deepEqual(moveKey(["a", "b", "c", "d"], "d", "b"), ["a", "d", "b", "c"]);
  assert.deepEqual(moveKey(["a", "b", "c", "d"], "a", null), ["b", "c", "d", "a"]);
  assert.deepEqual(moveKey(["a", "b", "c"], "b", "b"), ["a", "b", "c"]);
});

test("the columns that grow share the room the others leave, in whole pixels", () => {
  assert.deepEqual(fill([100, 200, 100], [0, 1, 0], 600), [100, 400, 100]);
  // Shares: 1 and 2 of 300.
  assert.deepEqual(fill([100, 100, 100], [1, 0, 2], 600), [200, 100, 300]);
  // 101 in three: the last takes what the rounding leaves.
  assert.deepEqual(fill([100, 100, 100], [1, 1, 1], 401), [133, 133, 135]);
  // A fraction of a pixel of room is not drawn.
  assert.deepEqual(fill([100, 100], [1, 0], 300.6), [200, 100]);
});

test("a box no wider than the columns, or no column that grows, leaves them as they are", () => {
  assert.deepEqual(fill([100, 200], [1, 0], 300), [100, 200]);
  assert.deepEqual(fill([100, 200], [1, 0], 250), [100, 200]);
  assert.deepEqual(fill([100, 200], [0, 0], 600), [100, 200]);
  assert.deepEqual(fill([], [], 600), []);
});
