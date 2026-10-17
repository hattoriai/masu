import { test } from "node:test";
import assert from "node:assert/strict";
import { fromTSV, inputText, parseNumber, placePaste, sendValue, shownValue } from "../src/parse";
import { toTSV } from "../src/tsv";

test("parseNumber() reads a number in the locale, or gives the text back", () => {
  assert.equal(parseNumber("1,234.5", "en-US"), "1234.5");
  assert.equal(parseNumber("1.234,5", "de-DE"), "1234.5");
  assert.equal(parseNumber("1 234,5", "fr-FR"), "1234.5");
  assert.equal(parseNumber("1234.5", "de-DE"), "1234.5");
  assert.equal(parseNumber("-12", "en-US"), "-12");
  assert.equal(parseNumber(" ", "en-US"), "");
  assert.equal(parseNumber("twelve", "en-US"), "twelve");
});

test("fromTSV() reads what toTSV() writes, quotes and line breaks too", () => {
  const rows = [["a\tb", 'say "hi"', "one\ntwo", "plain"], ["", "x", "", ""]];
  assert.deepEqual(fromTSV(toTSV(rows)), rows);
  assert.deepEqual(fromTSV("1\t2\r\n3\t4\r\n"), [["1", "2"], ["3", "4"]]);
  assert.deepEqual(fromTSV("only"), [["only"]]);
});

test("placePaste() puts rows from the top left, within the grid", () => {
  const selection = { top: 8, left: 1, bottom: 8, right: 1 };
  assert.deepEqual(placePaste([["a", "b"], ["c", "d"]], selection, 10, 3), [
    { row: 8, col: 1, text: "a" },
    { row: 8, col: 2, text: "b" },
    { row: 9, col: 1, text: "c" },
    { row: 9, col: 2, text: "d" },
  ]);
  assert.equal(placePaste([["a", "b", "c"]], selection, 10, 3).length, 2);
  assert.equal(placePaste([["a"], ["b"], ["c"]], selection, 10, 3).length, 2);
});

test("one value pasted on a range fills it", () => {
  const placed = placePaste([["x"]], { top: 0, left: 0, bottom: 1, right: 1 }, 10, 3);
  assert.deepEqual(placed.map((p) => `${p.row}${p.col}${p.text}`), ["00x", "01x", "10x", "11x"]);
});

test("the editor's text, what it sends, and what the cell shows meanwhile", () => {
  assert.equal(inputText("decimal", "120.50"), "120.50");
  assert.equal(inputText("integer", null), "");
  assert.equal(inputText("datetime", "2026-10-17T09:05:00"), "2026-10-17T09:05:00");
  assert.equal(sendValue("decimal", "1,234.50", "en-US"), "1234.50");
  assert.equal(sendValue("text", "  keep spaces ", "en"), "  keep spaces ");
  assert.equal(sendValue("text", "   ", "en"), null);
  assert.equal(sendValue("boolean", "TRUE", "en"), true);
  assert.equal(sendValue("boolean", "no", "en"), false);
  assert.equal(shownValue("integer", "42"), 42);
  assert.equal(shownValue("decimal", "42.10"), "42.10");
});
