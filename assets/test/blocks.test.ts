import { test } from "node:test";
import assert from "node:assert/strict";
import { BlockCache } from "../src/blocks";
import type { Row } from "../src/types";

const rows = (from: number, count: number): Row[] => Array.from({ length: count }, (_, i) => [from + i, `row ${from + i}`]);

test("stores rows across blocks and reads them back", () => {
  const cache = new BlockCache(10);
  cache.store(5, rows(5, 10));
  assert.deepEqual(cache.get(5), [5, "row 5"]);
  assert.deepEqual(cache.get(14), [14, "row 14"]);
  assert.equal(cache.get(4), undefined);
  assert.equal(cache.get(15), undefined);
});

test("a block is missing until all its rows are there, up to the total", () => {
  const cache = new BlockCache(10);
  cache.store(0, rows(0, 6));
  assert.deepEqual(cache.missing(0, 29, 25), [0, 1, 2]);
  cache.store(6, rows(6, 4));
  cache.store(20, rows(20, 5));
  assert.deepEqual(cache.missing(0, 29, 25), [1]);
});

test("a block asked for is not missing until it comes or fails", () => {
  const cache = new BlockCache(10);
  cache.ask(1);
  assert.deepEqual(cache.missing(0, 29, 30), [0, 2]);
  cache.failed(1);
  assert.deepEqual(cache.missing(0, 29, 30), [0, 1, 2]);
  cache.ask(2);
  cache.store(20, rows(20, 10));
  assert.deepEqual(cache.missing(20, 29, 30), []);
});

test("missing() clamps to the rows that exist", () => {
  const cache = new BlockCache(10);
  assert.deepEqual(cache.missing(-50, 5, 3), [0]);
  assert.deepEqual(cache.missing(0, 10, 0), []);
  assert.deepEqual(cache.missing(40, 50, 30), []);
});

test("evict() forgets the blocks farthest from the center", () => {
  const cache = new BlockCache(10, 3);
  for (let block = 0; block < 6; block++) cache.store(block * 10, rows(block * 10, 10));
  cache.evict(4);
  assert.equal(cache.blockCount, 3);
  assert.notEqual(cache.get(45), undefined);
  assert.equal(cache.get(5), undefined);
  cache.clear();
  assert.equal(cache.blockCount, 0);
});
