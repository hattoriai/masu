import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_HEIGHT, boxHeight, toContent, toScroll, wheelPixels } from "../src/scroll";

test("a grid shorter than a browser draws keeps its height", () => {
  assert.equal(boxHeight(36_000), 36_000);
  assert.equal(boxHeight(MAX_HEIGHT), MAX_HEIGHT);
});

test("a taller grid gets the largest height, below every browser's limit", () => {
  assert.equal(boxHeight(36_000_000), MAX_HEIGHT);
  // Firefox draws no element taller than 17,895,697 pixels.
  assert.ok(MAX_HEIGHT < 17_895_697);
});

test("the ends of the scroll box are the ends of the content", () => {
  assert.equal(toContent(0, 9_000_000, 35_000_000), 0);
  assert.equal(toContent(9_000_000, 9_000_000, 35_000_000), 35_000_000);
  assert.equal(toScroll(0, 9_000_000, 35_000_000), 0);
  assert.equal(toScroll(35_000_000, 9_000_000, 35_000_000), 9_000_000);
});

test("between the ends, the place in the content is the place of the scrollbar", () => {
  assert.equal(toContent(4_500_000, 9_000_000, 36_000_000), 18_000_000);
  assert.equal(toScroll(18_000_000, 9_000_000, 36_000_000), 4_500_000);
  assert.equal(toContent(toScroll(1_234_567, 9_000_000, 36_000_000), 9_000_000, 36_000_000), 1_234_567);
});

test("a scrollbar a pixel or two from its end is at the end, as Firefox stops there", () => {
  assert.equal(toContent(8_999_998, 9_000_000, 35_000_000), 35_000_000);
  assert.ok(toContent(8_999_990, 9_000_000, 35_000_000) < 35_000_000);
});

test("a place out of the content is its nearest end", () => {
  assert.equal(toContent(-5, 9_000_000, 35_000_000), 0);
  assert.equal(toContent(9_000_100, 9_000_000, 35_000_000), 35_000_000);
  assert.equal(toScroll(36_000_000, 9_000_000, 35_000_000), 9_000_000);
});

test("a box with no room to scroll is at the top", () => {
  assert.equal(toContent(0, 0, 0), 0);
  assert.equal(toScroll(0, 0, 0), 0);
});

test("a wheel moves by pixels, lines of rows, or screens", () => {
  // WheelEvent.deltaMode: 0 pixels, 1 lines, 2 pages.
  assert.equal(wheelPixels(120, 0, 36, 500), 120);
  assert.equal(wheelPixels(3, 1, 36, 500), 108);
  assert.equal(wheelPixels(-1, 2, 36, 500), -500);
});
