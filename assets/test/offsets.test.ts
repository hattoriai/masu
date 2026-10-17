import { test } from "node:test";
import assert from "node:assert/strict";
import { indexAt, rowTop, totalHeight } from "../src/offsets";

const gaps = [
  { index: 2, height: 100 },
  { index: 5, height: 50 },
];

test("a row is under the rows and the gaps above it", () => {
  assert.equal(rowTop(0, 10, gaps), 0);
  assert.equal(rowTop(2, 10, gaps), 20);
  assert.equal(rowTop(3, 10, gaps), 130);
  assert.equal(rowTop(6, 10, gaps), 210);
  assert.equal(rowTop(4, 10, []), 40);
});

test("the height of the rows has the gaps of the rows there are", () => {
  assert.equal(totalHeight(10, 10, gaps), 250);
  assert.equal(totalHeight(4, 10, gaps), 140);
});

test("the row at a height: in a gap, the row it opens under", () => {
  assert.equal(indexAt(0, 10, gaps), 0);
  assert.equal(indexAt(25, 10, gaps), 2);
  assert.equal(indexAt(29, 10, gaps), 2);
  assert.equal(indexAt(30, 10, gaps), 2);
  assert.equal(indexAt(129, 10, gaps), 2);
  assert.equal(indexAt(130, 10, gaps), 3);
  assert.equal(indexAt(160, 10, gaps), 5);
  assert.equal(indexAt(209, 10, gaps), 5);
  assert.equal(indexAt(210, 10, gaps), 6);
  for (let index = 0; index < 9; index++) assert.equal(indexAt(rowTop(index, 10, gaps), 10, gaps), index);
});
